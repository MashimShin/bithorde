/****************************************************************************************
 *   Copyright: Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
 *
 *   License:
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ***************************************************************************************/
module lib.client;

private import tango.core.Exception;
private import tango.io.selector.Selector;
private import tango.math.random.Random;
private import tango.net.device.Socket;
private import tango.time.Time;
private import tango.util.container.more.Stack;
private import tango.util.log.Log;

public import lib.asset;
import lib.connection;
import lib.protobuf;

alias void delegate(Object) DEvent;
extern (C) void rt_attachDisposeEvent(Object h, DEvent e);

/****************************************************************************************
 * RemoteAsset is the basic BitHorde object for tracking a remotely open asset form the
 * client-side.
 ***************************************************************************************/
class RemoteAsset : private IAsset {
    /************************************************************************************
     * Internal ReadRequest object, for tracking in-flight readrequests.
     ***********************************************************************************/
    class ReadRequest : message.ReadRequest {
        BHReadCallback _callback;
        ushort retries;
        this(BHReadCallback cb, ushort retries=0) {
            this.handle = this.outer.handle;
            this.retries = retries;
            _callback = cb;
        }
        void callback(message.Status s, message.ReadResponse resp) {
            if ((s == message.Status.TIMEOUT) && retries) {
                retries -= 1;
                client.sendRequest(this);
            } else {
                _callback(this.outer, s, this, resp);
            }
        }
        void abort(message.Status s) {
            callback(s, null);
        }
    }
    /************************************************************************************
     * Internal MetaDataRequest object, for tracking in-flight MetaDataRequests.
     ***********************************************************************************/
    class MetaDataRequest : message.MetaDataRequest {
        BHMetaDataCallback _callback;
        this(BHMetaDataCallback cb) {
            this.handle = this.outer.handle;
            _callback = cb;
        }
        void callback(message.MetaDataResponse resp) {
            _callback(this.outer, resp.status, this, resp);
        }
        void abort(message.Status s) {
            _callback(this.outer, s, this, null);
        }
    }
private:
    Client client;
    bool closed;
    void clientGone(Object o) {
        this.client = null;
    }
protected:
    /************************************************************************************
     * RemoteAssets should only be created from the Client
     ***********************************************************************************/
    this(Client c, message.OpenRequest req, message.OpenResponse resp) {
        this(c, req.handle, resp);
        this.requestIds = req.ids;
    }
    this(Client c, message.UploadRequest req, message.OpenResponse resp) {
        this(c, req.handle, resp);
    }
    this(Client c, ushort handle, message.OpenResponse resp) {
        rt_attachDisposeEvent(c, &clientGone); // Add hook for invalidating client-reference
        this.client = c;
        this.handle = handle;
        this._size = resp.size;
    }
    ~this() {
        if (!closed)
            close();
    }
public:
    ushort handle;
    ulong _size;
    message.Identifier[] requestIds;

    /************************************************************************************
     * aSyncRead as of IAsset. With or without explicit retry-count
     ***********************************************************************************/
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback) {
        this.aSyncRead(offset, size, readCallback, 5, TimeSpan.fromMillis(6000));
    }
    /// ditto
    void aSyncRead(ulong offset, uint size, BHReadCallback readCallback, ushort retries, TimeSpan timeout) {
        auto req = new ReadRequest(readCallback, retries);
        req.offset = offset;
        req.size = size;
        client.sendRequest(req, timeout);
    }

    void requestMetaData(BHMetaDataCallback cb) {
        auto req = new MetaDataRequest(cb);
        client.sendRequest(req);
    }

    void sendDataSegment(ulong offset, ubyte[] data) {
        auto msg = new message.DataSegment;
        msg.handle = handle;
        msg.offset = offset;
        msg.content = data;
        client.sendMessage(msg);
    }

    final ulong size() {
        return _size;
    }

    void close() {
        closed = true;
        if (client) {
            if (!client.closed) {
                scope req = new message.Close;
                req.handle = handle;
                client.sendMessage(req);
            }
            client.onAssetClosed(this);
        }
    }
}

/****************************************************************************************
 * The Client class handles an ongoing client-session with a remote Bithorde-node. The
 * Client is the main-point of the Client API. To access BitHorde, just create a Client
 * with some address, and start fetching.
 *
 * Worth mentioning is that the entire client API is asynchronous, meaning that no remote
 * calls return anything immediately, but later through a required callback.
 *
 * Most applications will want to use the SimpleClient for basic operations.
 *
 * The Client is not thread-safe at this moment.
 ***************************************************************************************/
class Client {
protected:
    /************************************************************************************
     * Internal outgoing UploadRequest object
     ***********************************************************************************/
    static class UploadRequest : message.UploadRequest {
        BHOpenCallback callback;
        this(BHOpenCallback cb) {
            this.callback = cb;
        }
        void abort(message.Status s) {
            callback(null, s, this, null);
        }
    }

    /************************************************************************************
     * Internal outgoing OpenRequest object
     ***********************************************************************************/
    static class OpenRequest : message.OpenRequest {
        BHOpenCallback callback;
        this(BHOpenCallback cb) {
            this.callback = cb;
        }
        void abort(message.Status s) {
            callback(null, s, this, null);
        }
    }
private:
    RemoteAsset[uint] openAssets;
    Stack!(ushort) freeAssetHandles;
    ushort nextNewHandle;
    protected Logger log;
public:
    Connection connection;
    /************************************************************************************
     * Create a BitHorde client by name and an IPv4Address, or a LocalAddress.
     ***********************************************************************************/
    this (Address addr, char[] name)
    {
        this.log = Log.lookup("lib.client");
        connection = new Connection(name, &process);
        connect(addr);
    }

    /************************************************************************************
     * Create BitHorde client on provided Socket
     ***********************************************************************************/
    this (Socket s, char[] name) {
        this.log = Log.lookup("lib.client");
        connection = new Connection(name, &process);
        connection.handshake(s);
    }

    /************************************************************************************
     * Connect to specified address
     ***********************************************************************************/
    protected Socket connect(Address addr) {
        auto socket = new Socket(addr.addressFamily, SocketType.STREAM, ProtocolType.IP);
        socket.connect(addr);
        connection.handshake(socket);
        return socket;
    }

    char[] peername() {
        return connection.peername;
    }

    void close()
    {
        auto assets = openAssets.values;
        foreach (asset; assets)
            asset.close();
        connection.close();
    }

    /************************************************************************************
     * Attempt to open an asset identified by any of a set of ids.
     *
     * Params:
     *     ids           =  A list of ids to match. Priorities, and outcome of conflicts
     *                      in ID:s are undefined
     *     openCallback  =  A callback to be notified when the open request has completed
     *     timeout       =  (optional) How long to wait before automatically failing the
     *                      request. Defaults to 500msec.
     ***********************************************************************************/
    void open(message.Identifier[] ids,
              BHOpenCallback openCallback, TimeSpan timeout = TimeSpan.fromMillis(3000)) {
        open(ids, true, openCallback, rand.uniformR2!(ulong)(1,ulong.max), timeout);
    }

    /************************************************************************************
     * Query about an asset without binding it to handle.
     ***********************************************************************************/
    void stat(message.Identifier[] ids, BHOpenCallback openCallback,
        TimeSpan timeout = TimeSpan.fromMillis(3000)) {
        open(ids, false, openCallback, rand.uniformR2!(ulong)(1,ulong.max), timeout);
    }

    /************************************************************************************
     * Create a new remote asset for uploading
     ***********************************************************************************/
    void beginUpload(ulong size, BHOpenCallback cb) {
        auto req = new UploadRequest(cb);
        req.handle = this.allocateFreeHandle();
        req.size = size;
        sendRequest(req);
    }
protected:
    synchronized void sendMessage(message.Message msg) {
        connection.sendMessage(msg);
    }
    synchronized void sendRequest(message.RPCRequest req, TimeSpan timeout=TimeSpan.fromMillis(4000)) {
        connection.sendRequest(req, timeout);
    }
    bool closed() {
        return connection.closed;
    }

    void process(Connection c, message.Type type, ubyte[] msg) {
        try {
            with (message) switch (type) {
            case Type.HandShake: throw new Connection.InvalidMessage("Handshake not allowed after initialization");
            case Type.OpenRequest: processOpenRequest(c, msg); break;
            case Type.UploadRequest: processUploadRequest(c, msg); break;
            case Type.OpenResponse: processOpenResponse(c, msg); break;
            case Type.Close: processClose(c, msg); break;
            case Type.ReadRequest: processReadRequest(c, msg); break;
            case Type.ReadResponse: processReadResponse(c, msg); break;
            case Type.DataSegment: processDataSegment(c, msg); break;
            case Type.MetaDataRequest: processMetaDataRequest(c, msg); break;
            case Type.MetaDataResponse: processMetaDataResponse(c, msg); break;
            default: throw new Connection.InvalidMessage;
            }
        } catch (Connection.InvalidMessage exc) {
            log.warn("Exception in processing Message: {}", exc);
        }
    }

    /************************************************************************************
     * Real open-function, but should only be used internally by bithorde.
     ***********************************************************************************/
    void open(message.Identifier[] ids, bool do_bind, BHOpenCallback openCallback, ulong uuid,
              TimeSpan timeout) {
        auto req = new OpenRequest(openCallback);
        req.ids = ids;
        req.uuid = uuid;
        if (do_bind)
            req.handle = allocateFreeHandle;
        sendRequest(req, timeout);
    }

    /************************************************************************************
     * Cleanup after a closed RemoteAsset
     ***********************************************************************************/
    protected void onAssetClosed(RemoteAsset asset) {
        openAssets.remove(asset.handle);
        freeAssetHandles.push(asset.handle);
    }

    /************************************************************************************
     * Allocates an unused file handle for the transaction.
     ***********************************************************************************/
    protected ushort allocateFreeHandle()
    {
        if (freeAssetHandles.size > 0)
            return freeAssetHandles.pop();
        else
            return nextNewHandle++;
    }

    synchronized void processOpenResponse(Connection c, ubyte[] buf) {
        scope resp = new message.OpenResponse;
        resp.decode(buf);
        auto basereq = cast(message.OpenOrUploadRequest)c.releaseRequest(resp);
        if (basereq) {
            RemoteAsset asset;
            if (resp.status == message.Status.SUCCESS) {
                if (basereq.typeId == message.Type.UploadRequest) {
                    asset = new RemoteAsset(this, cast(UploadRequest)basereq, resp);
                } else if (basereq.typeId == message.Type.OpenRequest) {
                    asset = new RemoteAsset(this, cast(OpenRequest)basereq, resp);
                }
                openAssets[basereq.handle] = asset;
            } else if (basereq.handleIsSet){
                freeAssetHandles.push(basereq.handle);
            }
            if (basereq.typeId == message.Type.UploadRequest) {
                auto req = cast(UploadRequest)basereq;
                req.callback(asset, resp.status, req, resp);
            } else if (basereq.typeId == message.Type.OpenRequest) {
                auto req = cast(OpenRequest)basereq;
                req.callback(asset, resp.status, req, resp);
            }
        } else {
            assert(basereq, "OpenResponse, but not OpenOrUploadRequest");
        }
    }
    synchronized void processReadResponse(Connection c, ubyte[] buf) {
        scope resp = new message.ReadResponse;
        resp.decode(buf);
        auto req = cast(RemoteAsset.ReadRequest)c.releaseRequest(resp);
        assert(req, "ReadResponse, but not ReadRequest");
        req.callback(resp.status, resp);
    }
    synchronized void processMetaDataResponse(Connection c, ubyte[] buf) {
        scope resp = new message.MetaDataResponse;
        resp.decode(buf);
        auto req = cast(RemoteAsset.MetaDataRequest)c.releaseRequest(resp);
        assert(req, "MetaDataResponse, but not MetaDataRequest");
        req.callback(resp);
    }
    void processOpenRequest(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processClose(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processReadRequest(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processUploadRequest(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
    void processDataSegment(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get segment data!", __FILE__, __LINE__);
    }
    void processMetaDataRequest(Connection c, ubyte[] buf) {
        throw new AssertException("Danger Danger! This client should not get requests!", __FILE__, __LINE__);
    }
}

/****************************************************************************************
 * Client with standalone pump() and run()-mechanisms. Appropriate for most client-
 * applications.
 ***************************************************************************************/
class SimpleClient : Client {
private:
    Selector selector;
public:
    /************************************************************************************
     * Create client by name, and connect to given address.
     *
     * The SimpleClient is driven by the application in some manner, either by
     * continually calling pump(), or yielding to run(), which will run the client until
     * it is closed.
     ***********************************************************************************/
    this (Address addr, char[] name)
    {
        super(addr, name);
    }

    /************************************************************************************
     * Intercept new connection and create Selector for it
     ***********************************************************************************/
    protected Socket connect(Address addr) {
        auto retval = super.connect(addr);
        selector = new Selector();
        selector.open(1,1);
        selector.register(retval, Event.Read|Event.Error);
        return retval;
    }

    /************************************************************************************
     * Handle remote-side-initiated disconnect. Can be supplemented/overridden in
     * subclasses.
     ***********************************************************************************/
    protected void onDisconnected() {
        close();
    }

    /************************************************************************************
     * Run exactly one cycle of readNewData, processMessage*, processTimeouts
     ***********************************************************************************/
    synchronized void pump() {
        if (selector.select(connection.nextTimeOut) > 0) {
            foreach (key; selector.selectedSet()) {
                if (key.isReadable) {
                    auto read = connection.readNewData();
                    if (read)
                        while (connection.processMessage()) {}
                    else
                        onDisconnected();
                } else if (key.isError) {
                    onDisconnected();
                }
            }
        }
        connection.processTimeouts();
    }

    /************************************************************************************
     * Run until closed. Assumes that the calling application is completely event-driven,
     * by the callbacks triggered when recieving responses from BitHorde (or on
     * timeout:s).
     ***********************************************************************************/
    void run() {
        while (!closed)
            pump();
    }
}
