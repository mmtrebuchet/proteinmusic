module waved.wav;

import std.range,
       std.file,
       std.array,
       std.string;

import waved.utils;

/// Supports Microsoft WAV audio file format.


// wFormatTag
immutable int LinearPCM = 0x0001;
immutable int FloatingPointIEEE = 0x0003;
immutable int WAVE_FORMAT_EXTENSIBLE = 0xFFFE;


/// Decodes a WAV file.
/// Throws: WavedException on error.
Sound decodeWAV(string filepath)
{
    auto bytes = cast(ubyte[]) std.file.read(filepath);
    return decodeWAV(bytes);
}

/// Encodes a WAV file.
/// Throws: WavedException on error.
void encodeWAV(Sound sound, string filepath)
{
    auto output = appender!(ubyte[])();
    output.encodeWAV(sound);
    std.file.write(filepath, output.data);
}

/// Decodes a WAV.
/// Throws: WavedException on error.
Sound decodeWAV(R)(R input) if (isInputRange!R)
{
    // check RIFF header
    {
        uint chunkId, chunkSize;
        getRIFFChunkHeader(input, chunkId, chunkSize);
        if (chunkId != RIFFChunkId!"RIFF")
            throw new WavedException("Expected RIFF chunk.");

        if (chunkSize < 4)
            throw new WavedException("RIFF chunk is too small to contain a format.");

        if (popBE!uint(input) !=  RIFFChunkId!"WAVE")
            throw new WavedException("Expected WAVE format.");
    }    

    bool foundFmt = false;
    bool foundData = false;

    
    int audioFormat;
    int numChannels;
    int sampleRate;
    int byteRate;
    int blockAlign;
    int bitsPerSample;

    Sound result;
    // while chunk is not
    while (!input.empty)
    {
        // Some corrupted WAV files in the wild finish with one
        // extra 0 byte after an AFAn chunk, very odd
        static if (hasLength!R)
        {
            if (input.length == 1 && input.front() == 0)
                break;
        }

        uint chunkId, chunkSize;
        getRIFFChunkHeader(input, chunkId, chunkSize); 
        if (chunkId == RIFFChunkId!"fmt ")
        {
            if (foundFmt)
                throw new WavedException("Found several 'fmt ' chunks in RIFF file.");

            foundFmt = true;

            if (chunkSize < 16)
                throw new WavedException("Expected at least 16 bytes in 'fmt ' chunk."); // found in real-world for the moment: 16 or 40 bytes

            audioFormat = popLE!ushort(input);
            if (audioFormat == WAVE_FORMAT_EXTENSIBLE)
                throw new WavedException("No support for format WAVE_FORMAT_EXTENSIBLE yet."); // Reference: http://msdn.microsoft.com/en-us/windows/hardware/gg463006.aspx
            
            if (audioFormat != LinearPCM && audioFormat != FloatingPointIEEE)
                throw new WavedException(format("Unsupported audio format %s, only PCM and IEEE float are supported.", audioFormat));

            numChannels = popLE!ushort(input);

            sampleRate = popLE!uint(input);
            if (sampleRate <= 0)
                throw new WavedException(format("Unsupported sample-rate %s.", cast(uint)sampleRate)); // we do not support sample-rate higher than 2^31hz

            uint bytesPerSec = popLE!uint(input);
            int bytesPerFrame = popLE!ushort(input);
            bitsPerSample = popLE!ushort(input);

            if (bitsPerSample != 8 && bitsPerSample != 16 && bitsPerSample != 24 && bitsPerSample != 32 && bitsPerSample != 64) 
                throw new WavedException(format("Unsupported bitdepth %s.", cast(uint)bitsPerSample));

            if (bytesPerFrame != (bitsPerSample / 8) * numChannels)
                throw new WavedException("Invalid bytes-per-second, data might be corrupted.");

            skipBytes(input, chunkSize - 16);
        }
        else if (chunkId == RIFFChunkId!"data")
        {
            if (foundData)
                throw new WavedException("Found several 'data' chunks in RIFF file.");

            if (!foundFmt)
                throw new WavedException("'fmt ' chunk expected before the 'data' chunk.");

            int bytePerSample = bitsPerSample / 8;
            uint frameSize = numChannels * bytePerSample;
            if (chunkSize % frameSize != 0)
                throw new WavedException("Remaining bytes in 'data' chunk, inconsistent with audio data type.");

            uint numFrames = chunkSize / frameSize;
            uint numSamples = numFrames * numChannels;

            result.samples.length = numSamples;

            if (audioFormat == FloatingPointIEEE)
            {
                if (bytePerSample == 4)
                {
                    for (uint i = 0; i < numSamples; ++i)
                        result.samples[i] = popFloatLE(input);
                }
                else if (bytePerSample == 8)
                {
                    for (uint i = 0; i < numSamples; ++i)
                        result.samples[i] = popDoubleLE(input);
                }
                else
                    throw new WavedException("Unsupported bit-depth for floating point data, should be 32 or 64.");
            }
            else if (audioFormat == LinearPCM)
            {
                if (bytePerSample == 1)
                {
                    for (uint i = 0; i < numSamples; ++i)
                    {
                        ubyte b = popUbyte(input);
                        result.samples[i] = (b - 128) / 127.0;
                    }
                }
                else if (bytePerSample == 2)
                {
                    for (uint i = 0; i < numSamples; ++i)
                    {
                        int s = popLE!short(input);
                        result.samples[i] = s / 32767.0;
                    }
                }
                else if (bytePerSample == 3)
                {
                    for (uint i = 0; i < numSamples; ++i)
                    {
                        int s = pop24bitsLE!R(input);
                        result.samples[i] = s / 8388607.0;
                    }
                }
                else if (bytePerSample == 4)
                {
                    for (uint i = 0; i < numSamples; ++i)
                    {
                        int s = popLE!int(input);
                        result.samples[i] = s / 2147483648.0;
                    }
                }
                else
                    throw new WavedException("Unsupported bit-depth for integer PCM data, should be 8, 16, 24 or 32 bits.");
            }
            else
                assert(false); // should have been handled earlier, crash

            foundData = true;
        }
        else
        {
            // ignore unrecognized chunks
            skipBytes(input, chunkSize);
        }
    }

    if (!foundFmt)
        throw new WavedException("'fmt ' chunk not found.");

    if (!foundData)
        throw new WavedException("'data' chunk not found.");
 

    result.channels = numChannels;
    result.sampleRate = sampleRate;

    return result;
}


/// Encodes a WAV.
void encodeWAV(R)(ref R output, Sound sound) if (isOutputRange!(R, ubyte))
{
    // for now let's just pretend always saving to 32-bit float is OK


    // Avoid a number of edge cases.
    if (sound.channels < 0 || sound.channels > 1024)
        throw new WavedException(format("Can't save a WAV with %s channels.", sound.channels));

    // RIFF header
    output.writeRIFFChunkHeader(RIFFChunkId!"RIFF", 4 + (4 + 4 + 16) + (4 + 4 + float.sizeof * sound.samples.length) );
    output.writeBE!uint(RIFFChunkId!"WAVE");

    // 'fmt ' sub-chunk
    output.writeRIFFChunkHeader(RIFFChunkId!"fmt ", 0x10);
    output.writeLE!ushort(FloatingPointIEEE);
    
    output.writeLE!ushort(cast(ushort)(sound.channels));

    if (sound.sampleRate == 0)
        throw new WavedException("Can't save a WAV with sample-rate of 0hz. Assign the sampleRate field.");

    output.writeLE!uint(cast(uint)(sound.sampleRate));

    size_t bytesPerSec = sound.sampleRate * sound.channels * float.sizeof;
    output.writeLE!uint( cast(uint)(bytesPerSec));

    int bytesPerFrame = cast(int)(sound.channels * float.sizeof);
    output.writeLE!ushort(cast(ushort)bytesPerFrame);

    output.writeLE!ushort(32);

    // data sub-chunk
    output.writeRIFFChunkHeader(RIFFChunkId!"data", float.sizeof * sound.samples.length);
    foreach (float f; sound.samples)
        output.writeFloatLE(f);
}

