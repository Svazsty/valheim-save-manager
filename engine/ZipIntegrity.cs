// ZipArchive in .NET Framework does not expose CRC32 and may not verify it.
// Read checksums from the central directory, then verify every decompressed byte.
using System;
using System.IO;
using System.IO.Compression;

namespace ValheimSaveManager
{
    public static class ZipIntegrity
    {
        private static readonly uint[] Table = MakeTable();
        private static uint[] MakeTable()
        {
            var table = new uint[256];
            for (uint n = 0; n < table.Length; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xedb88320U ^ (c >> 1) : c >> 1;
                table[n] = c;
            }
            return table;
        }

        public static void Verify(string path)
        {
            using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var reader = new BinaryReader(file))
            using (var zip = new ZipArchive(file, ZipArchiveMode.Read, true))
            {
                long end = -1;
                long first = Math.Max(0, file.Length - 65557);
                for (long p = file.Length - 22; p >= first; p--)
                {
                    file.Position = p;
                    if (reader.ReadUInt32() != 0x06054b50U) continue;
                    file.Position = p + 20;
                    if (p + 22 + reader.ReadUInt16() == file.Length) { end = p; break; }
                }
                if (end < 0) throw new InvalidDataException("Brak poprawnego konca ZIP.");
                file.Position = end + 4;
                ushort disk = reader.ReadUInt16(), directoryDisk = reader.ReadUInt16();
                ushort diskCount = reader.ReadUInt16(), count = reader.ReadUInt16();
                uint size = reader.ReadUInt32(), offset = reader.ReadUInt32();
                if (disk != 0 || directoryDisk != 0 || diskCount != count)
                    throw new InvalidDataException("Dzielone archiwum ZIP nie jest obslugiwane.");
                ulong entryCount = count, directoryOffset = offset, directorySize = size;
                if (count == 0xffff || offset == 0xffffffffU || size == 0xffffffffU)
                {
                    if (end < 20) throw new InvalidDataException("Brak lokalizatora ZIP64.");
                    file.Position = end - 20;
                    if (reader.ReadUInt32() != 0x07064b50U || reader.ReadUInt32() != 0)
                        throw new InvalidDataException("Niepoprawny lokalizator ZIP64.");
                    ulong zip64Offset = reader.ReadUInt64();
                    if (reader.ReadUInt32() != 1 || zip64Offset > (ulong)(end - 56))
                        throw new InvalidDataException("Niepoprawna pozycja ZIP64.");
                    file.Position = (long)zip64Offset;
                    if (reader.ReadUInt32() != 0x06064b50U || reader.ReadUInt64() < 44)
                        throw new InvalidDataException("Niepoprawny naglowek ZIP64.");
                    reader.ReadUInt16(); reader.ReadUInt16();
                    if (reader.ReadUInt32() != 0 || reader.ReadUInt32() != 0)
                        throw new InvalidDataException("Dzielone archiwum ZIP64.");
                    ulong onDisk = reader.ReadUInt64();
                    entryCount = reader.ReadUInt64();
                    directorySize = reader.ReadUInt64(); directoryOffset = reader.ReadUInt64();
                    if (onDisk != entryCount) throw new InvalidDataException("Niepoprawna liczba wpisow ZIP64.");
                }
                if (entryCount != (ulong)zip.Entries.Count || directoryOffset > (ulong)end ||
                    directorySize > (ulong)end - directoryOffset)
                    throw new InvalidDataException("Niepoprawny katalog centralny ZIP.");
                long position = (long)directoryOffset;
                var buffer = new byte[81920];
                foreach (var entry in zip.Entries)
                {
                    file.Position = position;
                    if (reader.ReadUInt32() != 0x02014b50U) throw new InvalidDataException("Niepoprawny wpis ZIP.");
                    file.Position = position + 16;
                    uint expected = reader.ReadUInt32();
                    file.Position = position + 28;
                    ushort nameLength = reader.ReadUInt16(), extraLength = reader.ReadUInt16(), commentLength = reader.ReadUInt16();
                    position = checked(position + 46 + nameLength + extraLength + commentLength);
                    if ((ulong)position > directoryOffset + directorySize) throw new InvalidDataException("Wpis poza katalogiem ZIP.");
                    uint crc = 0xffffffffU;
                    long bytes = 0;
                    using (var source = entry.Open())
                    {
                        int length;
                        while ((length = source.Read(buffer, 0, buffer.Length)) != 0)
                        {
                            bytes = checked(bytes + length);
                            for (int i = 0; i < length; i++) crc = Table[(crc ^ buffer[i]) & 0xff] ^ (crc >> 8);
                        }
                    }
                    if ((crc ^ 0xffffffffU) != expected || bytes != entry.Length)
                        throw new InvalidDataException("Uszkodzone dane ZIP (CRC32): " + entry.FullName);
                }
            }
        }
    }
}
