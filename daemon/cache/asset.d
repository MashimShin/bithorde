/****************************************************************************************
 * All the different variants of Cache-Assets
 *
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
module daemon.cache.asset;

private import tango.core.Exception;
private import tango.core.Thread;
private import tango.core.Signal;
private import tango.core.WeakRef;
private import tango.io.device.File;
private import tango.io.FilePath;
version (Posix) private import tango.stdc.posix.unistd;
private import ascii = tango.text.Ascii;
private import tango.util.log.Log;
private import tango.time.Clock;
private import tango.time.Time;

private import lib.client;
private import lib.hashes;
private import lib.message;

private import daemon.cache.metadata;
private import daemon.cache.map;
private import daemon.client;

static if ( !is(typeof(fdatasync) == function ) )
    extern (C) int fdatasync(int);

const LOCALID_LENGTH = 32;

private static ThreadLocal!(ubyte[]) tls_buf;
private static this() {
    tls_buf = new ThreadLocal!(ubyte[]);
}
private static ubyte[] tlsBuffer(uint size) {
    auto buf = tls_buf.val;
    if (buf == (ubyte[]).init) {
        buf = new ubyte[size];
        tls_buf.val = buf;
    } else if (size > buf.length) {
        buf.length = size;
    }
    return buf;
}

alias void delegate(Identifier[]) HashIdsListener;

/****************************************************************************************
 * Base for all kinds of cached assets. Provides basic reading functionality
 ***************************************************************************************/
class BaseAsset : private File, public IServerAsset {
    mixin IAsset.StatusSignal;
protected:
    FilePath path;
    FilePath idxPath;
    Logger log;
    AssetMetaData _metadata;
public:
    /************************************************************************************
     * IncompleteAssetException is thrown if a not-fully-cached asset were to be Opened
     * directly as a BaseAsset
     ***********************************************************************************/
    this(FilePath path, AssetMetaData metadata) {
        this.path = path;
        this.idxPath = path.dup.suffix(".idx");
        this._metadata = metadata;
        log = Log.lookup("daemon.cache.baseasset."~path.name[0..8]);

        super();
        assetOpen(path);
    }

    /************************************************************************************
     * assetOpen - Overridable function to really open or create the asset.
     ***********************************************************************************/
    void assetOpen(FilePath path) {
        File.open(path.toString);
    }

    /************************************************************************************
     * Asset is closed, unregistered, and resources closed. Afterwards, should be
     * awaiting garbage collection.
     ***********************************************************************************/
    void close() {
        super.close();
    }

    /************************************************************************************
     * Implements IServerAsset.hashIds()
     * TODO: IServerAsset perhaps should be migrated to MetaData?
     ***********************************************************************************/
    Identifier[] hashIds() {
        if (_metadata)
            return _metadata.hashIds;
        else
            return null;
    }

    /************************************************************************************
     * Read a single segment from the Asset
     ***********************************************************************************/
    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        ubyte[] buf = tlsBuffer(length);
        version (Posix) { // Posix has pread() for atomic seek+read
            auto got = pread(fileHandle, buf.ptr, length, offset);
        } else {
            seek(offset);
            auto got = read(buf);
        }
        auto resp = new lib.message.ReadResponse;
        if (got == 0 || got == Eof) {
            resp.status = message.Status.NOTFOUND;
        } else {
            _metadata.noteInterest(Clock.now, (cast(float)got)/cast(float)size);
            resp.status = message.Status.SUCCESS;
            resp.offset = offset;
            resp.content = buf[0..got];
        }
        cb(this, resp.status, null, resp); // TODO: should really hold reference to req
    }

    /************************************************************************************
     * Adding segments is not supported for BaseAsset
     ***********************************************************************************/
    void add(ulong offset, ubyte[] data) {
        throw new IOException("Trying to write to a completed file");
    }

    /************************************************************************************
     * Find the size of the asset.
     ***********************************************************************************/
    final ulong size() {
        return length;
    }
}

/****************************************************************************************
 * WriteableAsset implements uploading to Assets, and forms a base for CachingAsset
 ***************************************************************************************/
class WriteableAsset : BaseAsset {
protected:
    CacheMap cacheMap;
    Digest[HashType] hashes;
    ulong hashedPtr;
    HashIdsListener updateHashIds;
public:
    /************************************************************************************
     * Create WriteableAsset by path and size
     ***********************************************************************************/
    this(FilePath path, AssetMetaData metadata, ulong size, HashIdsListener updateHashIds) {
        foreach (k,hash; HashMap)
            hashes[hash.pbType] = hash.factory();
        this.updateHashIds = updateHashIds;
        super(path, metadata); // Parent calls open()
        truncate(size);           // We resize it to right size
        log = Log.lookup("daemon.cache.writeasset."~path.name[0..8]);
    }

    /************************************************************************************
     * Create and open a WriteableAsset. Make sure to create cacheMap first, create the
     * file, and then truncate it to the right size.
     ***********************************************************************************/
    void assetOpen(FilePath path) {
        this.cacheMap = new CacheMap(idxPath);
        File.open(path.toString, File.Style(File.Access.ReadWrite, File.Open.Sedate));
    }

    /************************************************************************************
     * Asynchronous read, first checking the cacheMap has the block we're looking for.
     ***********************************************************************************/
    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        if (length == 0) {
            cb(this, message.Status.SUCCESS, null, null);
        } else if (this.cacheMap && !this.cacheMap.has(offset, length)) {
            cb(this, message.Status.NOTFOUND, null, null);
        } else {
            super.aSyncRead(offset, length, cb);
        }
    }

    /************************************************************************************
     * Add a data-segment to the asset, and update the CacheMap
     ***********************************************************************************/
    synchronized void add(ulong offset, ubyte[] data) {
        if (!cacheMap)
            throw new IOException("Trying to write to a completed file");
        version (Posix) { // Posix has pwrite() for atomic write+seek
            auto written = pwrite(fileHandle, data.ptr, data.length, offset);
        } else {
            seek(offset);
            auto written = write(data);
        }
        if (written == data.length) {
            cacheMap.add(offset, written);
            updateHashes();
        } else {
            throw new IOException("Failed to write received segment. Disk full?");
        }
    }

    /************************************************************************************
     * Make sure to synchronize file data, and flush cachemap to disk.
     ***********************************************************************************/
    void sync() {
        scope CacheMap cmapToWrite;
        synchronized (this) {
            if (!cacheMap)
                return;
            cmapToWrite = new CacheMap(cacheMap);
        }
        version (Posix)
            fdatasync(fileHandle);
        else
            static assert(false, "Needs Non-POSIX implementation");
        cmapToWrite.sync();
    }
protected:
    /************************************************************************************
     * Check if more data is available for hashing
     ***********************************************************************************/
    void updateHashes() {
        auto zeroBlockSize = cacheMap.zeroBlockSize;
        if (zeroBlockSize > hashedPtr) {
            auto bufsize = zeroBlockSize - hashedPtr;
            auto buf = tlsBuffer(bufsize);
            auto got = pread(fileHandle, buf.ptr, bufsize, hashedPtr);
            assert(got == bufsize);
            foreach (hash; hashes) {
                hash.update(buf[0..bufsize]);
            }
            if (zeroBlockSize == length)
                finish();
            else
                hashedPtr = zeroBlockSize;
        }
    }

    /************************************************************************************
     * Post-finish hooks. Finalize the digests, add to assetMap, and remove the CacheMap
     ***********************************************************************************/
    synchronized void finish() {
        assert(updateHashIds);
        assert(cacheMap);
        assert(cacheMap.segcount == 1);
        assert(cacheMap.assetSize == length);
        log.trace("Asset complete");

        auto hashIds = new message.Identifier[hashes.length];
        uint i;
        foreach (type, hash; hashes) {
            auto digest = hash.binaryDigest;
            auto hashId = new message.Identifier;
            hashId.type = type;
            hashId.id = digest.dup;
            hashIds[i++] = hashId;
        }

        updateHashIds(hashIds);

        auto oldCache = cacheMap;
        cacheMap = null;
        sync();
        oldCache.path.remove();

        _statusSignal.call(this, message.Status.SUCCESS, null);
    }
}

/****************************************************************************************
 * CachingAsset is an important workhorse in the entire system. Implements a currently
 * caching asset, still not completely locally available.
 ***************************************************************************************/
class CachingAsset : WriteableAsset {
    IServerAsset remoteAsset;

    /************************************************************************************
     * Structure holding WeakReference to this, so we can attach it to events without
     * preventing GC of this.
     ***********************************************************************************/
    struct RemoteWatcher {
        WeakReference!(CachingAsset) assetRef;
        void setAsset(CachingAsset asset) {
            assetRef = new typeof(assetRef)(asset);
        }
        void onBackingUpdate(IAsset backing, message.Status sCode, message.AssetStatus s) {
            auto asset = assetRef();
            if (asset)
                asset._statusSignal.call(asset, sCode, s);
        }
    }
public:
    this (FilePath path, AssetMetaData metadata, IServerAsset remoteAsset, HashIdsListener updateHashIds) {
        this.remoteAsset = remoteAsset;
        auto watcher = new RemoteWatcher();
        watcher.setAsset(this);
        remoteAsset.attachWatcher(&watcher.onBackingUpdate);
        super(path, metadata, remoteAsset.size, updateHashIds); // TODO: Verify remoteAsset.size against local file
        log = Log.lookup("daemon.cache.cachingasset." ~ path.name[0..8]);
        log.trace("Caching remoteAsset of size {}", size);
    }

    synchronized void aSyncRead(ulong offset, uint length, BHReadCallback cb) {
        auto r = new ForwardedRead;
        r.offset = offset;
        r.length = length;
        r.cb = cb;
        r.tryRead();
    }
protected:
    /************************************************************************************
     * Triggered when the underlying cache is complete.
     ***********************************************************************************/
    void finish() body {
        // TODO: Validate hashId:s
        super.finish();
        remoteAsset = null;
    }
private:
    void realRead(ulong offset, uint length, BHReadCallback cb) {
        super.aSyncRead(offset, length, cb);
    }

    /************************************************************************************
     * Every read-operation for non-cached data results in a ForwardedRead, which tracks
     * a forwarded ReadRequest, recieves the response, and updates the CachingAsset.
     ***********************************************************************************/
    class ForwardedRead {
        ulong offset;
        uint length;
        BHReadCallback cb;
        message.Status lastStatus;
        uint tries;

        void tryRead() {
            if (!cacheMap || cacheMap.has(offset, length)) {
                realRead(offset, length, cb);
                delete this;
            } else if (tries++ < 4) {
                remoteAsset.aSyncRead(offset, length, &callback);
            } else {
                fail();
            }
        }
        void fail() {
            auto resp = new lib.message.ReadResponse;
            resp.status = message.Status.NOTFOUND;
            cb(this.outer, resp.status, null, resp);
        }
        void callback(IAsset asset, message.Status status, message.ReadRequest req, message.ReadResponse resp) {
            if (status == message.Status.SUCCESS && resp && resp.content.length) {
                if (cacheMap) // May no longer be open for writing, due to stale requests
                    add(resp.offset, resp.content);
                tryRead();
            } else if ((status == message.Status.DISCONNECTED) && (status != lastStatus)) { // Hackish. We may have double-requested the same part of the file, so attempt to read it anyways
                lastStatus = status;
                tryRead();
            } else {
                log.warn("Failed forwarded read, with error {}", status);
                fail();
            }
            delete req;
        }
    }
}

