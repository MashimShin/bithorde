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
 **************************************************************************************/

/*******************************************************************************

    This module is used to decode and encode base32 char[] arrays.

    Example:
    ---
    char[] blah = "Hello there, my name is Jeff.";

    scope encodebuf = new char[allocateEncodeSize(cast(ubyte[])blah)];
    char[] encoded = encode(cast(ubyte[])blah, encodebuf);

    scope decodebuf = new ubyte[encoded.length];
    if (cast(char[])decode(encoded, decodebuf) == "Hello there, my name is Jeff.")
        Stdout("yay").newline;
    ---

*******************************************************************************/

module lib.base32;

/*******************************************************************************

    calculates and returns the size needed to encode the length of the
    array passed.

    Params:
    data = An array that will be encoded

*******************************************************************************/


uint allocateEncodeSize(ubyte[] data)
{
    return allocateEncodeSize(data.length);
}

/*******************************************************************************

    calculates and returns the size needed to encode the length passed.

    Params:
    length = Number of bytes to be encoded

*******************************************************************************/

uint allocateEncodeSize(uint length)
{
    auto inputbits = length * 8;
    auto inputquantas = (inputbits + 39) / 40; // Round upwards
    return inputquantas * 8;
}


/*******************************************************************************

    encodes data and returns as an ASCII base32 string.

    Params:
    data = what is to be encoded
    buff = buffer large enough to hold encoded data
    pad  = Whether to pad ascii output with '='-chars

    Example:
    ---
    char[512] encodebuf;
    char[] myEncodedString = encode(cast(ubyte[])"Hello, how are you today?", encodebuf);
    Stdout(myEncodedString).newline; // JBSWY3DPFQQGQ33XEBQXEZJAPFXXKIDUN5SGC6J7
    ---


*******************************************************************************/

char[] encode(ubyte[] data, char[] buff, bool pad=true)
in
{
    assert(data);
    assert(buff.length >= allocateEncodeSize(data));
}
body
{
    uint i = 0;
    ushort remainder; // Carries overflow bits to next char
    byte remainlen;  // Tracks bits in remainder
    foreach (ubyte j; data)
    {
        remainder = (remainder<<8) | j;
        remainlen += 8;
        do {
            remainlen -= 5;
            buff[i++] = _encodeTable[(remainder>>remainlen)&0b11111];
        } while (remainlen > 5)
    }
    if (remainlen)
        buff[i++] = _encodeTable[(remainder<<(5-remainlen))&0b11111];
    if (pad) {
        for (ubyte padCount=(-i%8);padCount > 0; padCount--)
            buff[i++] = base32_PAD;
    }

    return buff[0..i];
}

/*******************************************************************************

    encodes data and returns as an ASCII base32 string.

    Params:
    data = what is to be encoded
    pad = whether to pad output with '='-chars

    Example:
    ---
    char[] myEncodedString = encode(cast(ubyte[])"Hello, how are you today?");
    Stdout(myEncodedString).newline; // JBSWY3DPFQQGQ33XEBQXEZJAPFXXKIDUN5SGC6J7
    ---


*******************************************************************************/


char[] encode(ubyte[] data, bool pad=true)
in
{
    assert(data);
}
body
{
    auto rtn = new char[allocateEncodeSize(data)];
    return encode(data, rtn, pad);
}

/*******************************************************************************

    decodes an ASCII base32 string and returns it as ubyte[] data. Pre-allocates
    the size of the array.

    This decoder will ignore non-base32 characters. So:
    SGVsbG8sIGhvd
    yBhcmUgeW91IH
    RvZGF5Pw==

    Is valid.

    Params:
    data = what is to be decoded

    Example:
    ---
    char[] myDecodedString = cast(char[])decode("JBSWY3DPFQQGQ33XEBQXEZJAPFXXKIDUN5SGC6J7");
    Stdout(myDecodeString).newline; // Hello, how are you today?
    ---

*******************************************************************************/

ubyte[] decode(char[] data)
in
{
    assert(data);
}
body
{
    auto rtn = new ubyte[data.length];
    return decode(data, rtn);
}

/*******************************************************************************

    decodes an ASCII base32 string and returns it as ubyte[] data.

    This decoder will ignore non-base32 characters. So:
    SGVsbG8sIGhvd
    yBhcmUgeW91IH
    RvZGF5Pw==

    Is valid.

    Params:
    data = what is to be decoded
    buff = a big enough array to hold the decoded data

    Example:
    ---
    ubyte[512] decodebuf;
    char[] myDecodedString = cast(char[])decode("JBSWY3DPFQQGQ33XEBQXEZJAPFXXKIDUN5SGC6J7", decodebuf);
    Stdout(myDecodeString).newline; // Hello, how are you today?
    ---

*******************************************************************************/
ubyte[] decode(char[] data, ubyte[] buff)
in
{
    assert(data);
}
body
{
    ushort remainder;
    byte remainlen;
    size_t oIndex;
    foreach (c; data)
    {
        auto dec = _decodeTable[c];
        if (dec & 0b1000_0000)
            continue;
        remainder = (remainder<<5) | dec;
        for (remainlen += 5; remainlen >= 8; remainlen -= 8)
            buff[oIndex++] = remainder >> (remainlen-8);
    }

    return buff[0..oIndex];
}

debug (UnitTest)
{
    unittest
    {
        static char[][] testBytes = [
            "",
            "foo",
            "foob",
            "fooba",
            "foobar",
            "Hello, how are you today?",
        ];
        static char[][] testChars = [
            "",
            "MZXW6===",
            "MZXW6YQ=",
            "MZXW6YTB",
            "MZXW6YTBOI======",
            "JBSWY3DPFQQGQ33XEBQXEZJAPFXXKIDUN5SGC6J7",
        ];

        for (uint i; i < testBytes.length; i++) {
            auto resultChars = encode(cast(ubyte[])testBytes[i]);
            assert(resultChars == testChars[i],
                    testBytes[i]~": ("~resultChars~") != ("~testChars[i]~")");

            auto resultBytes = decode(testChars[i]);
            assert(resultBytes == cast(ubyte[])testBytes[i],
                    testChars[i]~": ("~cast(char[])resultBytes~") != ("~testBytes[i]~")");
        }
    }
}



private:

/*
    Static immutable tables used for fast lookups to
    encode and decode data.
*/
static const ubyte base32_PAD = '=';
static const char[] _encodeTable = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

static const ubyte[] _decodeTable = [
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0x1A,0x1B, 0x1C,0x1D,0x1E,0x1F, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0x00,0x01,0x02, 0x03,0x04,0x05,0x06, 0x07,0x08,0x09,0x0A, 0x0B,0x0C,0x0D,0x0E,
    0x0F,0x10,0x11,0x12, 0x13,0x14,0x15,0x16, 0x17,0x18,0x19,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF,
];
