<#
  Fix-FakeUSB  v1.0
  Finds the REAL size of a fake-capacity USB stick (e.g. sold as "2 TB", really 32 GB),
  shrinks it to that size, checks every byte, and formats it - so phones and PCs show
  the true size from then on.

  HOW TO RUN
    Double-click Fix-FakeUSB.bat (keep it in the same folder as this file),
    or right-click this file > "Run with PowerShell". It asks for Administrator rights.

  SAFETY
    - Only USB disks are listed. System/boot disks are never touched.
    - Nothing is written until you type WIPE <disk number>.
    - The disk identity (name, serial, size) is re-checked before every destructive step.
    - Everything on the stick is erased.

  Windows 10/11, built-in Windows PowerShell 5.1. Nothing to install.
#>
param([int]$Disk = -1)

$ErrorActionPreference = 'Stop'
$Margin = 0.95            # final partition = 95% of the measured real size (safety margin)

# ------------------------------------------------------------------ elevate
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Asking for Administrator rights (needed to write to the stick directly)...'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    } catch {
        Write-Host 'Administrator rights are required. Right-click Fix-FakeUSB.bat > Run as administrator.' -ForegroundColor Red
        Read-Host 'Press Enter to close' | Out-Null
    }
    exit
}

try { $Host.UI.RawUI.WindowTitle = 'Fix fake USB stick' } catch {}

# ------------------------------------------------------------------ engine (C#, compiled on the fly)
$CoreSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FakeUsb
{
    internal static class Native
    {
        public const uint GENERIC_READ = 0x80000000;
        public const uint GENERIC_WRITE = 0x40000000;
        public const uint FILE_SHARE_READ = 1;
        public const uint FILE_SHARE_WRITE = 2;
        public const uint OPEN_EXISTING = 3;
        public const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
        public const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
        public const uint MEM_COMMIT = 0x1000;
        public const uint MEM_RESERVE = 0x2000;
        public const uint MEM_RELEASE = 0x8000;
        public const uint PAGE_READWRITE = 4;
        public const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(SafeFileHandle h, IntPtr buf, int count, out int done, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteFile(SafeFileHandle h, IntPtr buf, int count, out int done, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPos, uint method);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FlushFileBuffers(SafeFileHandle h);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize, out long outBuf, int outSize, out int returned, IntPtr overlapped);
    }

    // Page-aligned memory (unbuffered disk I/O needs sector-aligned buffers).
    public sealed class AlignedBuffer : IDisposable
    {
        public IntPtr Ptr;
        public int Size;
        bool virt;

        public AlignedBuffer(int size)
        {
            Size = size;
            if (Environment.OSVersion.Platform == PlatformID.Win32NT)
            {
                Ptr = Native.VirtualAlloc(IntPtr.Zero, new UIntPtr((uint)size), Native.MEM_COMMIT | Native.MEM_RESERVE, Native.PAGE_READWRITE);
                virt = true;
            }
            else
            {
                Ptr = Marshal.AllocHGlobal(size);
            }
            if (Ptr == IntPtr.Zero) throw new OutOfMemoryException("Cannot allocate I/O buffer");
        }

        public void Dispose()
        {
            if (Ptr == IntPtr.Zero) return;
            if (virt) Native.VirtualFree(Ptr, UIntPtr.Zero, Native.MEM_RELEASE);
            else Marshal.FreeHGlobal(Ptr);
            Ptr = IntPtr.Zero;
        }
    }

    public abstract class BlockDev : IDisposable
    {
        public long Length;
        public int Sector = 512;
        // Return 0 on success, otherwise a Win32 error code (or -1 for a short transfer).
        public abstract int Write(long offset, IntPtr buf, int len);
        public abstract int Read(long offset, IntPtr buf, int len);
        public abstract void Flush();
        public virtual void Dispose() { }
    }

    public sealed class RawDisk : BlockDev
    {
        SafeFileHandle h;
        public string Path;

        public RawDisk(int diskNumber, int sectorSize)
        {
            Path = @"\\.\PhysicalDrive" + diskNumber;
            h = Native.CreateFileW(Path, Native.GENERIC_READ | Native.GENERIC_WRITE,
                Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero, Native.OPEN_EXISTING,
                Native.FILE_FLAG_NO_BUFFERING | Native.FILE_FLAG_WRITE_THROUGH, IntPtr.Zero);
            if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open " + Path);
            long len;
            int ret;
            if (!Native.DeviceIoControl(h, Native.IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, out len, 8, out ret, IntPtr.Zero))
            {
                int e = Marshal.GetLastWin32Error();
                h.Dispose();
                throw new Win32Exception(e, "Cannot read size of " + Path);
            }
            Length = len;
            Sector = sectorSize > 0 ? sectorSize : 512;
        }

        int Seek(long offset)
        {
            long np;
            return Native.SetFilePointerEx(h, offset, out np, 0) ? 0 : Marshal.GetLastWin32Error();
        }

        public override int Write(long offset, IntPtr buf, int len)
        {
            int e = Seek(offset);
            if (e != 0) return e;
            int n;
            if (!Native.WriteFile(h, buf, len, out n, IntPtr.Zero))
            {
                e = Marshal.GetLastWin32Error();
                return e == 0 ? -1 : e;
            }
            return n == len ? 0 : -1;
        }

        public override int Read(long offset, IntPtr buf, int len)
        {
            int e = Seek(offset);
            if (e != 0) return e;
            int n;
            if (!Native.ReadFile(h, buf, len, out n, IntPtr.Zero))
            {
                e = Marshal.GetLastWin32Error();
                return e == 0 ? -1 : e;
            }
            return n == len ? 0 : -1;
        }

        public override void Flush() { Native.FlushFileBuffers(h); }

        public override void Dispose()
        {
            if (h != null && !h.IsClosed) h.Dispose();
        }
    }

    public static class Ui
    {
        public static bool Quiet = false;

        public static bool CancelRequested()
        {
            try
            {
                while (Console.KeyAvailable)
                {
                    if (Console.ReadKey(true).Key == ConsoleKey.Escape) return true;
                }
            }
            catch { }
            return false;
        }

        public static void Progress(string s)
        {
            if (Quiet) return;
            try
            {
                int w = 79;
                try { w = Math.Max(40, Console.WindowWidth - 1); } catch { }
                if (s.Length > w) s = s.Substring(0, w);
                Console.Write("\r" + s.PadRight(w));
            }
            catch { }
        }

        public static void EndLine()
        {
            if (Quiet) return;
            try { Console.WriteLine(); } catch { }
        }

        public static string Eta(double secs)
        {
            if (double.IsNaN(secs) || double.IsInfinity(secs) || secs < 0) return "--:--:--";
            TimeSpan t = TimeSpan.FromSeconds(Math.Min(secs, 359999));
            return string.Format("{0:00}:{1:00}:{2:00}", (int)t.TotalHours, t.Minutes, t.Seconds);
        }

        public static string Mbs(double bytesPerSec) { return (bytesPerSec / 1e6).ToString("0.0") + " MB/s"; }
        public static string Gib(long b) { return (b / 1073741824.0).ToString("0.00") + " GiB"; }
        public static string Of(long a, long b) { return (a / 1073741824.0).ToString("0.00") + "/" + (b / 1073741824.0).ToString("0.00") + " GiB"; }
    }

    // Test data: every block carries a header (magic, its own address, run nonce, size)
    // followed by pseudo-random bytes derived from that header, so any block can be checked
    // later and a block that shows up at the wrong address reveals where it was written.
    public static class Pattern
    {
        public const long Magic = 0x3154535442535546L; // "FUSBTST1"
        public const int OK = 0, ALIAS = 1, ZERO = 2, ONES = 3, GARBAGE = 4, CORRUPT = 5, WRITE_ERR = 6, READ_ERR = 7;

        static readonly string[] names = {
            "ok",
            "wraps around (data written there lands on another address)",
            "throws data away (reads back zeros)",
            "throws data away (reads back FF)",
            "throws data away (reads back junk)",
            "corrupts data",
            "refuses writes (I/O error)",
            "refuses reads (I/O error)"
        };

        public static string Name(int s) { return (s >= 0 && s < names.Length) ? names[s] : "unknown"; }

        static ulong Mix(ulong z)
        {
            z += 0x9E3779B97F4A7C15UL;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }

        public static void Gen(long[] dst, int idx, int words, long offset, long nonce)
        {
            dst[idx] = Magic;
            dst[idx + 1] = offset;
            dst[idx + 2] = nonce;
            dst[idx + 3] = (long)words * 8;
            ulong s = Mix((ulong)offset ^ (ulong)nonce);
            if (s == 0) s = 0x2545F4914F6CDD1DUL;
            int end = idx + words;
            for (int i = idx + 4; i < end; i++)
            {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                dst[i] = (long)s;
            }
            // Keep bytes 510-511 at zero so a block that lands on sector 0 never looks like an MBR.
            if (words > 63) dst[idx + 63] &= 0x0000FFFFFFFFFFFFL;
        }

        public static int Check(long[] got, int idx, int words, long offset, long nonce, long[] scratch, out long aliasFrom)
        {
            aliasFrom = -1;
            if (got[idx] == Magic && got[idx + 2] == nonce && got[idx + 3] == (long)words * 8)
            {
                long hdr = got[idx + 1];
                if (hdr != offset) { aliasFrom = hdr; return ALIAS; }
                Gen(scratch, 0, words, offset, nonce);
                for (int i = 4; i < words; i++)
                {
                    if (got[idx + i] != scratch[i]) return CORRUPT;
                }
                return OK;
            }
            bool zero = true, ones = true;
            for (int i = 0; i < words && (zero || ones); i++)
            {
                long v = got[idx + i];
                if (v != 0) zero = false;
                if (v != -1L) ones = false;
            }
            if (zero) return ZERO;
            if (ones) return ONES;
            return GARBAGE;
        }
    }

    public sealed class ProbeResult
    {
        public long Length, Step, Block;
        public int Count, GoodCount, AliasCount, DiscardCount, CorruptCount, IoErrCount, GoodAfterBoundary;
        public long LastGoodOffset = -1, FirstBadOffset = -1, FirstBadAliasFrom = -1;
        public int FirstBadStatus = -1;
        public long KnownGood;   // every test block below this address held its data
        public bool AllGood, Cancelled, Dead;
        public double WriteSeconds, ReadSeconds;
        public string FirstBadReason { get { return Pattern.Name(FirstBadStatus); } }
    }

    public sealed class FillResult
    {
        public long Start, End, WrittenEnd, VerifiedEnd, BytesRead;
        public long SafeEnd = -1;   // everything in [Start, SafeEnd) was written and read back correctly
        public long FirstBadOffset = -1, FirstBadAliasFrom = -1;
        public int FirstBadStatus = -1;
        public long BadMiB;
        // Wrap-around fakes overwrite the start of the stick when you write past the real size.
        // Those cells are physically fine but held foreign data; [Start, DirtyEnd) should be
        // re-verified once more (0 = nothing to re-check).
        public long DirtyEnd;
        public bool Completed, Cancelled, StoppedEarly;
        public double WriteMBps, ReadMBps, WriteSeconds, ReadSeconds;
        public bool Passed { get { return Completed && !Cancelled && !StoppedEarly && BadMiB == 0 && FirstBadOffset < 0; } }
        public string FirstBadReason { get { return Pattern.Name(FirstBadStatus); } }
    }

    public sealed class MeasureResult
    {
        public long RealSize;          // every byte in [0, RealSize) was written and read back correctly
        public bool Verified;          // RealSize is fully proven (no leftovers to re-check)
        public bool Cancelled;
        public bool WholeRangeClean;   // no fake behaviour anywhere in the tested range
        public long FirstBadOffset = -1;
        public int FirstBadStatus = -1;
        public double WriteMBps, ReadMBps, Seconds;
        public int Passes;
        public string FirstBadReason { get { return Pattern.Name(FirstBadStatus); } }
    }

    public static class Core
    {
        public static long MinProbeStep = 64L << 20;   // 64 MiB
        public static int MaxProbeBlocks = 4096;
        public static long CheckEvery = 1L << 30;      // spot-check older data every 1 GiB written

        public static long NewNonce()
        {
            long n = BitConverter.ToInt64(Guid.NewGuid().ToByteArray(), 0);
            return n == 0 ? 1 : n;
        }

        // ---------------------------------------------------------------------------------
        // Quick probe: write one 64 KiB block every "step" bytes across the whole reported
        // size, HIGHEST address first, then read them all back. On a fake, blocks past the
        // real capacity either vanish (zeros/junk/I/O errors) or alias onto lower addresses;
        // writing top-down means the genuine low block is written last, so its alias shows a
        // foreign header and is caught. Real size ~= last good block before the first bad one.
        // ---------------------------------------------------------------------------------
        public static ProbeResult Probe(BlockDev d, long nonce)
        {
            ProbeResult r = new ProbeResult();
            long len = d.Length;
            r.Length = len;
            int blk = 64 * 1024;
            if (blk % d.Sector != 0) blk = d.Sector * ((blk + d.Sector - 1) / d.Sector);
            long step = MinProbeStep;
            while (len / step > MaxProbeBlocks) step <<= 1;
            r.Step = step;
            r.Block = blk;

            List<long> offs = new List<long>();
            for (long o = 0; o + blk <= len; o += step) offs.Add(o);
            long last = ((len - blk) / blk) * blk;
            if (offs.Count == 0 || last > offs[offs.Count - 1]) offs.Add(last);
            int n = offs.Count;
            r.Count = n;

            int[] st = new int[n];
            long[] alias = new long[n];
            for (int i = 0; i < n; i++) alias[i] = -1;
            int words = blk / 8;
            long[] gen = new long[words];
            long[] got = new long[words];
            long[] scr = new long[words];

            using (AlignedBuffer buf = new AlignedBuffer(blk))
            {
                Stopwatch sw = Stopwatch.StartNew();
                int consec = 0;
                int written = 0;
                for (int i = n - 1; i >= 0; i--)
                {
                    if (Ui.CancelRequested()) { r.Cancelled = true; break; }
                    Pattern.Gen(gen, 0, words, offs[i], nonce);
                    Marshal.Copy(gen, 0, buf.Ptr, words);
                    int e = d.Write(offs[i], buf.Ptr, blk);
                    written++;
                    if (e != 0)
                    {
                        st[i] = Pattern.WRITE_ERR;
                        consec++;
                        if (consec == 32)
                        {
                            // Many fakes reject every write past the real size. Instead of waiting
                            // through thousands of failures, binary-search the highest writable block.
                            int lo = -1, hi = i;
                            while (hi - lo > 1)
                            {
                                int mid = (int)(((long)lo + hi) / 2);
                                Pattern.Gen(gen, 0, words, offs[mid], nonce);
                                Marshal.Copy(gen, 0, buf.Ptr, words);
                                if (d.Write(offs[mid], buf.Ptr, blk) == 0) lo = mid; else hi = mid;
                            }
                            for (int k = lo + 1; k < i; k++) st[k] = Pattern.WRITE_ERR;
                            if (lo < 0) { r.Dead = true; break; }
                            i = lo + 1;   // loop decrement continues at lo
                            consec = 0;
                        }
                    }
                    else consec = 0;

                    if ((written & 15) == 0 || i == 0)
                    {
                        double done = n - i;
                        double rate = done / Math.Max(sw.Elapsed.TotalSeconds, 0.001);
                        Ui.Progress(string.Format("  Probe: writing test block {0}/{1}  ETA {2}  [Esc=stop]",
                            n - i, n, Ui.Eta(i / rate)));
                    }
                }
                r.WriteSeconds = sw.Elapsed.TotalSeconds;
                Ui.EndLine();
                if (r.Cancelled || r.Dead) return r;

                d.Flush();
                sw = Stopwatch.StartNew();
                consec = 0;
                for (int i = 0; i < n; i++)
                {
                    if (Ui.CancelRequested()) { r.Cancelled = true; break; }
                    if (st[i] == Pattern.WRITE_ERR) continue;
                    int e = d.Read(offs[i], buf.Ptr, blk);
                    if (e != 0)
                    {
                        st[i] = Pattern.READ_ERR;
                        consec++;
                        if (consec >= 64)
                        {
                            for (int k = i + 1; k < n; k++) if (st[k] != Pattern.WRITE_ERR) st[k] = Pattern.READ_ERR;
                            break;
                        }
                        continue;
                    }
                    consec = 0;
                    Marshal.Copy(buf.Ptr, got, 0, words);
                    long a;
                    st[i] = Pattern.Check(got, 0, words, offs[i], nonce, scr, out a);
                    alias[i] = a;
                    if ((i & 15) == 0 || i == n - 1)
                        Ui.Progress(string.Format("  Probe: reading back {0}/{1}  [Esc=stop]", i + 1, n));
                }
                r.ReadSeconds = sw.Elapsed.TotalSeconds;
                Ui.EndLine();
            }
            if (r.Cancelled) return r;

            for (int i = 0; i < n; i++)
            {
                switch (st[i])
                {
                    case Pattern.OK: r.GoodCount++; break;
                    case Pattern.ALIAS: r.AliasCount++; break;
                    case Pattern.ZERO:
                    case Pattern.ONES:
                    case Pattern.GARBAGE: r.DiscardCount++; break;
                    case Pattern.CORRUPT: r.CorruptCount++; break;
                    default: r.IoErrCount++; break;
                }
            }

            int kGood = 0;
            while (kGood < n && st[kGood] == Pattern.OK) kGood++;
            if (kGood == n)
            {
                r.AllGood = true;
                r.KnownGood = len;
                r.LastGoodOffset = offs[n - 1];
            }
            else
            {
                r.FirstBadOffset = offs[kGood];
                r.FirstBadStatus = st[kGood];
                r.FirstBadAliasFrom = alias[kGood];
                if (kGood > 0)
                {
                    r.LastGoodOffset = offs[kGood - 1];
                    r.KnownGood = offs[kGood - 1] + blk;
                }
                else r.KnownGood = 0;
                for (int j = kGood + 1; j < n; j++) if (st[j] == Pattern.OK) r.GoodAfterBoundary++;
            }
            return r;
        }

        static void Note(FillResult r, long off, int status, long aliasFrom)
        {
            if (r.FirstBadOffset < 0 || off < r.FirstBadOffset)
            {
                r.FirstBadOffset = off;
                r.FirstBadStatus = status;
                r.FirstBadAliasFrom = aliasFrom;
            }
        }

        // Lowest address proven to be past the real capacity, given one bad 1 MiB block at "off".
        // A foreign header means the block at "off" holds data written to "aliasFrom": whichever of
        // the two addresses is higher is the fake one.
        static long BadBound(int status, long off, long aliasFrom)
        {
            if (status == Pattern.ALIAS && aliasFrom >= 0) return Math.Max(off, aliasFrom);
            return off;
        }

        // ---------------------------------------------------------------------------------
        // Full write + read-back test of [start, end) (h2testw-style, on the raw device).
        // Writes ascending in 4 MiB chunks, spot-checks older data every CheckEvery bytes to
        // catch wrap-around early, then reads everything back.
        // SafeEnd = everything below it is proven good.
        // ---------------------------------------------------------------------------------
        public static FillResult Fill(BlockDev d, long start, long end, long nonce, bool stopEarly)
        {
            const int SUB = 1 << 20;
            const int CHUNK = 4 << 20;
            int subWords = SUB / 8;
            FillResult r = new FillResult();
            start = (start / SUB) * SUB;
            if (end > d.Length) end = d.Length;
            end = (end / SUB) * SUB;
            r.Start = start;
            r.End = end;
            r.WrittenEnd = start;
            r.VerifiedEnd = start;
            long bound = end;

            long[] gen = new long[CHUNK / 8];
            long[] got = new long[CHUNK / 8];
            long[] scr = new long[subWords];
            Random rnd = new Random((int)(nonce & 0x7FFFFFFF));
            long total = Math.Max(end - start, 1);
            List<long> aliasTargets = new List<long>();

            using (AlignedBuffer buf = new AlignedBuffer(CHUNK))
            {
                Stopwatch wsw = new Stopwatch();
                Stopwatch rsw = new Stopwatch();
                long pos = start;
                long nextCheck = start + CheckEvery;
                int consec = 0;

                // ---- write pass ----
                while (pos < end)
                {
                    if (Ui.CancelRequested()) { r.Cancelled = true; break; }
                    int len = (int)Math.Min((long)CHUNK, end - pos);
                    for (int s = 0; s < len; s += SUB) Pattern.Gen(gen, s / 8, subWords, pos + s, nonce);
                    Marshal.Copy(gen, 0, buf.Ptr, len / 8);
                    wsw.Start();
                    int e = d.Write(pos, buf.Ptr, len);
                    wsw.Stop();
                    if (e != 0)
                    {
                        Note(r, pos, Pattern.WRITE_ERR, -1);
                        if (pos < bound) bound = pos;
                        consec++;
                        if (stopEarly || consec >= 16)
                        {
                            r.StoppedEarly = true;
                            break;   // do not count this chunk as written
                        }
                    }
                    else consec = 0;
                    pos += len;
                    r.WrittenEnd = pos;

                    double rate = (pos - start) / Math.Max(wsw.Elapsed.TotalSeconds, 0.001);
                    Ui.Progress(string.Format("  Write  {0}  {1}  ETA {2}  [Esc=stop]",
                        Ui.Of(pos - start, total), Ui.Mbs(rate), Ui.Eta((end - pos) / rate)));

                    if (pos >= nextCheck || pos >= end)
                    {
                        nextCheck += CheckEvery;
                        d.Flush();
                        long nChunks = (pos - start + CHUNK - 1) / CHUNK;
                        for (int t = 0; t < 10; t++)
                        {
                            // newest chunk, first chunk (the first one a wrap-around overwrites), 8 random
                            long ci = (t == 0) ? nChunks - 1 : (t == 1 ? 0 : (long)(rnd.NextDouble() * nChunks));
                            if (ci >= nChunks) ci = nChunks - 1;
                            long off = start + ci * CHUNK;
                            int l = (int)Math.Min((long)CHUNK, pos - off);
                            if (l <= 0) continue;
                            rsw.Start();
                            int re = d.Read(off, buf.Ptr, l);
                            rsw.Stop();
                            if (re != 0)
                            {
                                Note(r, off, Pattern.READ_ERR, -1);
                                if (off < bound) bound = off;
                                continue;
                            }
                            Marshal.Copy(buf.Ptr, got, 0, l / 8);
                            for (int s = 0; s < l; s += SUB)
                            {
                                long a;
                                int stt = Pattern.Check(got, s / 8, subWords, off + s, nonce, scr, out a);
                                if (stt != Pattern.OK)
                                {
                                    long b = BadBound(stt, off + s, a);
                                    if (b < bound) bound = b;
                                }
                            }
                        }
                        if (stopEarly && bound < end)
                        {
                            r.StoppedEarly = true;
                            break;
                        }
                    }
                }
                Ui.EndLine();
                d.Flush();
                r.WriteSeconds = wsw.Elapsed.TotalSeconds;
                r.WriteMBps = (r.WrittenEnd - start) / Math.Max(r.WriteSeconds, 0.001) / 1e6;

                // ---- read-back pass ----
                if (!r.Cancelled)
                {
                    long rp = start;
                    long rEnd = r.WrittenEnd;
                    consec = 0;
                    while (rp < rEnd)
                    {
                        if (Ui.CancelRequested()) { r.Cancelled = true; break; }
                        int l = (int)Math.Min((long)CHUNK, rEnd - rp);
                        rsw.Start();
                        int re = d.Read(rp, buf.Ptr, l);
                        rsw.Stop();
                        if (re != 0)
                        {
                            Note(r, rp, Pattern.READ_ERR, -1);
                            if (rp < bound) bound = rp;
                            r.BadMiB += l / SUB;
                            rp += l;
                            consec++;
                            if (consec >= 16) break;
                            continue;
                        }
                        consec = 0;
                        Marshal.Copy(buf.Ptr, got, 0, l / 8);
                        for (int s = 0; s < l; s += SUB)
                        {
                            long a;
                            int stt = Pattern.Check(got, s / 8, subWords, rp + s, nonce, scr, out a);
                            if (stt != Pattern.OK)
                            {
                                r.BadMiB++;
                                Note(r, rp + s, stt, a);
                                long b = BadBound(stt, rp + s, a);
                                if (b < bound) bound = b;
                                if (stt == Pattern.ALIAS) aliasTargets.Add(rp + s);
                            }
                        }
                        rp += l;
                        r.BytesRead += l;
                        double rate = r.BytesRead / Math.Max(rsw.Elapsed.TotalSeconds, 0.001);
                        Ui.Progress(string.Format("  Read   {0}  {1}  ETA {2}  bad {3} MiB  [Esc=stop]",
                            Ui.Of(rp - start, rEnd - start), Ui.Mbs(rate), Ui.Eta((rEnd - rp) / rate), r.BadMiB));
                    }
                    r.VerifiedEnd = rp;
                    Ui.EndLine();
                    if (!r.Cancelled && rp >= rEnd && r.WrittenEnd >= end && !r.StoppedEarly) r.Completed = true;
                }
                r.ReadSeconds = rsw.Elapsed.TotalSeconds;
                r.ReadMBps = r.BytesRead / Math.Max(r.ReadSeconds, 0.001) / 1e6;
            }

            long safe = Math.Min(bound, r.VerifiedEnd);
            if (safe < start) safe = start;
            r.SafeEnd = (safe / SUB) * SUB;
            foreach (long t in aliasTargets)
            {
                if (t < r.SafeEnd && t + SUB > r.DirtyEnd) r.DirtyEnd = Math.Min(t + SUB, r.SafeEnd);
            }
            return r;
        }

        // Exact real size: fill [0, upper) until the drive misbehaves, then re-check any start
        // area a wrap-around overwrote. Result: [0, RealSize) is proven good.
        public static MeasureResult Measure(BlockDev d, long upper)
        {
            MeasureResult m = new MeasureResult();
            Stopwatch sw = Stopwatch.StartNew();
            FillResult f = Fill(d, 0, upper, NewNonce(), true);
            m.Passes = 1;
            m.WriteMBps = f.WriteMBps;
            m.ReadMBps = f.ReadMBps;
            m.FirstBadOffset = f.FirstBadOffset;
            m.FirstBadStatus = f.FirstBadStatus;
            if (f.Cancelled)
            {
                m.Cancelled = true;
                m.RealSize = f.SafeEnd;
                m.Seconds = sw.Elapsed.TotalSeconds;
                return m;
            }
            m.WholeRangeClean = f.Passed;
            long real = f.SafeEnd;
            long dirty = f.DirtyEnd;
            int guard = 0;
            while (dirty > 0 && guard < 3)
            {
                guard++;
                if (!Ui.Quiet)
                {
                    try { Console.WriteLine("  Re-checking the first " + Ui.Gib(dirty) + " (the fake overwrote it while being tested)"); } catch { }
                }
                FillResult g = Fill(d, 0, dirty, NewNonce(), true);
                m.Passes++;
                if (g.Cancelled)
                {
                    m.Cancelled = true;
                    m.RealSize = Math.Min(real, g.SafeEnd);
                    m.Seconds = sw.Elapsed.TotalSeconds;
                    return m;
                }
                if (g.Passed) { dirty = 0; break; }
                real = Math.Min(real, g.SafeEnd);
                dirty = Math.Min(g.DirtyEnd, real);
            }
            m.RealSize = real;
            m.Verified = (dirty == 0);
            m.Seconds = sw.Elapsed.TotalSeconds;
            return m;
        }
    }
}
'@

# ------------------------------------------------------------------ helpers
function Fmt([double]$b) {
    if ($b -lt 0) { return 'n/a' }
    return ('{0:N1} GB / {1:N1} GiB' -f ($b / 1e9), ($b / 1GB))
}

function Write-Step([string]$t) {
    Write-Host ''
    Write-Host ("== $t ==") -ForegroundColor Cyan
}

function Get-UsbDisks {
    return @(Get-Disk | Where-Object { [string]$_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem } | Sort-Object Number)
}

function Get-VidPid([int]$n) {
    try {
        $dd = Get-CimInstance -ClassName Win32_DiskDrive | Where-Object { $_.Index -eq $n } | Select-Object -First 1
        $devId = [string]$dd.PNPDeviceID
        for ($i = 0; $i -lt 5 -and $devId; $i++) {
            if ($devId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { return ('{0}:{1}' -f $matches[1], $matches[2]).ToUpper() }
            $p = Get-PnpDeviceProperty -InstanceId $devId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
            if ($p -and $p.Data) { $devId = [string]$p.Data } else { $devId = $null }
        }
    } catch {}
    return 'unknown'
}

function Get-DriveLetters([int]$n) {
    try {
        $l = @(Get-Partition -DiskNumber $n -ErrorAction Stop | Where-Object { [int]$_.DriveLetter -gt 0 } | ForEach-Object { "$($_.DriveLetter):" })
        if ($l.Count -gt 0) { return ($l -join ' ') }
    } catch {}
    return 'no drive letter'
}

function Get-Identity([int]$n) {
    $d = Get-Disk -Number $n
    return [pscustomobject]@{
        Number   = [int]$d.Number
        Name     = [string]$d.FriendlyName
        Serial   = ([string]$d.SerialNumber).Trim()
        Size     = [int64]$d.Size
        Sector   = [int]$d.LogicalSectorSize
        VidPid   = (Get-VidPid $n)
    }
}

function Assert-SameDisk($id) {
    try { Update-Disk -Number $id.Number -ErrorAction SilentlyContinue } catch {}
    $d = Get-Disk -Number $id.Number -ErrorAction Stop
    if ([string]$d.BusType -ne 'USB' -or $d.IsBoot -or $d.IsSystem) {
        throw "Disk $($id.Number) is no longer a USB data disk. Stopped for safety."
    }
    if ([int64]$d.Size -ne $id.Size -or ([string]$d.SerialNumber).Trim() -ne $id.Serial -or [string]$d.FriendlyName -ne $id.Name) {
        throw "Disk $($id.Number) is not the same stick anymore (unplugged or replugged?). Stopped for safety - run the tool again."
    }
}

function Invoke-Diskpart([string[]]$lines) {
    $tmp = Join-Path $env:TEMP ('fakeusb-diskpart-{0}.txt' -f $PID)
    Set-Content -Path $tmp -Encoding ASCII -Value $lines
    try { $out = & diskpart.exe /s $tmp } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { throw ("diskpart failed:`n" + ($out -join "`n")) }
}

# Remove every partition so the stick can be written directly.
function Reset-ToRaw($id) {
    Assert-SameDisk $id
    $n = $id.Number
    $d = Get-Disk -Number $n
    if ($d.IsOffline)  { try { Set-Disk -Number $n -IsOffline $false } catch {} }
    if ($d.IsReadOnly) { try { Set-Disk -Number $n -IsReadOnly $false } catch {} }
    if ([string]$d.PartitionStyle -ne 'RAW') {
        try {
            Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Host "  Clear-Disk failed ($($_.Exception.Message)) - trying diskpart..." -ForegroundColor Yellow
            Assert-SameDisk $id
            Invoke-Diskpart @("select disk $n", 'clean')
        }
        try { Update-Disk -Number $n -ErrorAction SilentlyContinue } catch {}
    }
}

function Open-Raw($id) {
    Assert-SameDisk $id
    $dev = New-Object FakeUsb.RawDisk -ArgumentList @($id.Number, $id.Sector)
    if ($dev.Length -ne $id.Size) {
        Write-Host ("  Note: the stick reports {0} to direct access (Windows said {1})." -f (Fmt $dev.Length), (Fmt $id.Size)) -ForegroundColor Yellow
    }
    return $dev
}

function Confirm-Wipe($id) {
    Write-Host ''
    Write-Host ("  EVERYTHING on disk {0} ({1}, reports {2}) will be ERASED." -f $id.Number, $id.Name, (Fmt $id.Size)) -ForegroundColor Red
    $want = 'WIPE{0}' -f $id.Number
    for ($try = 1; $try -le 5; $try++) {
        $a = [string](Read-Host ("  Type WIPE {0} to continue, or just press Enter to go back" -f $id.Number))
        $norm = ($a -replace '\s', '').ToUpper()
        if ($norm -eq '') { return $false }
        if ($norm -eq $want) { return $true }
        Write-Host ("  '{0}' does not match. Type exactly: WIPE {1}" -f $a.Trim(), $id.Number) -ForegroundColor Yellow
    }
    return $false
}

function Invoke-Probe($id) {
    Write-Step 'Step 1/3 - quick probe (small test blocks across the whole reported size)'
    Write-Host '  Usually 1-10 minutes.'
    $dev = Open-Raw $id
    try { $p = [FakeUsb.Core]::Probe($dev, [FakeUsb.Core]::NewNonce()) } finally { $dev.Dispose() }
    if ($p.Cancelled) { throw 'Stopped by you (Esc). The stick is now blank - run the tool again to finish.' }
    if ($p.Dead) { throw 'The stick refuses every write. It is broken - throw it away.' }
    Write-Host ("  Test blocks : {0} (one every {1:N2} GiB) - {2} good, {3} bad" -f $p.Count, ($p.Step / 1GB), $p.GoodCount, ($p.Count - $p.GoodCount))
    if ($p.AllGood) {
        Write-Host '  The quick probe found no fake behaviour. The full test will check every byte.' -ForegroundColor Yellow
    } else {
        Write-Host ("  Holds data up to about {0}" -f (Fmt $p.KnownGood)) -ForegroundColor Green
        Write-Host ("  Past {0} it {1}" -f (Fmt $p.FirstBadOffset), $p.FirstBadReason) -ForegroundColor Yellow
    }
    return $p
}

function Get-PartSize([int64]$real) {
    return [int64]([Math]::Floor(($real * $Margin - 1MB) / 1MB) * 1MB)
}

function Select-FileSystem([int64]$part) {
    if ($part -gt 32GB) { return 'exFAT' }
    Write-Host ''
    Write-Host '  File system:'
    Write-Host '    [1] exFAT  - phones, PCs, Macs, files over 4 GB (default)'
    Write-Host '    [2] FAT32  - old TVs, car radios, consoles (max 4 GB per file)'
    $a = Read-Host '  Choose 1 or 2'
    if ($a.Trim() -eq '2') { return 'FAT32' }
    return 'exFAT'
}

function Get-Label([int64]$part) {
    if ($part -ge 1e9) { return ('REAL{0}GB' -f [int][Math]::Floor($part / 1e9)) }
    return ('REAL{0}MB' -f [int][Math]::Floor($part / 1e6))
}

function New-RealPartition($id, [int64]$part, [string]$fs, [bool]$useMax) {
    $label = Get-Label $part
    if ($useMax) { $label = 'USB' }
    Write-Step ("Step 3/3 - creating the partition ({0}) and formatting it {1}" -f (Fmt $part), $fs)
    Write-Host '  If Windows pops up "You need to format the disk", click Cancel.' -ForegroundColor Yellow
    Reset-ToRaw $id
    $n = $id.Number
    $style = 'MBR'
    if ($useMax -and $id.Size -gt 2TB) { $style = 'GPT' }
    try {
        Initialize-Disk -Number $n -PartitionStyle $style -ErrorAction Stop
        if ($useMax) { $p = New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter -ErrorAction Stop }
        else         { $p = New-Partition -DiskNumber $n -Size $part -AssignDriveLetter -ErrorAction Stop }
        Start-Sleep -Seconds 2
        $null = Format-Volume -Partition $p -FileSystem $fs -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop
    } catch {
        Write-Host "  Windows storage commands failed ($($_.Exception.Message)) - using diskpart..." -ForegroundColor Yellow
        Assert-SameDisk $id
        $create = 'create partition primary'
        if (-not $useMax) { $create = 'create partition primary size={0}' -f [int64][Math]::Floor($part / 1MB) }
        Invoke-Diskpart @("select disk $n", 'clean', ('convert ' + $style.ToLower()), $create, ('format fs={0} quick label={1}' -f $fs.ToLower(), $label), 'assign')
    }
    Start-Sleep -Seconds 2
    try { Update-Disk -Number $n -ErrorAction SilentlyContinue } catch {}
    return [pscustomobject]@{ Letters = (Get-DriveLetters $n); Label = $label }
}

function Show-Report($id, $p, $m, [int64]$real, [int64]$part, $vol, [string]$fs, [bool]$verified, [bool]$genuine) {
    Write-Host ''
    Write-Host '================================ RESULT ================================' -ForegroundColor Cyan
    Write-Host ("  Stick            : {0} (disk {1}, VID:PID {2})" -f $id.Name, $id.Number, $id.VidPid)
    Write-Host ("  Sold/reported as : {0}" -f (Fmt $id.Size))
    if ($genuine) {
        Write-Host '  Real size        : matches the reported size - this stick is NOT fake' -ForegroundColor Green
    } elseif ($verified) {
        Write-Host ("  Real size        : {0}  (every byte written and read back)" -f (Fmt $real)) -ForegroundColor Green
    } else {
        Write-Host ("  Real size        : about {0}  (quick estimate, NOT verified)" -f (Fmt $real)) -ForegroundColor Yellow
    }
    $reason = $null
    if ($m -and $m.FirstBadOffset -ge 0) { $reason = $m.FirstBadReason } elseif ($p -and -not $p.AllGood) { $reason = $p.FirstBadReason }
    if ($reason -and -not $genuine) { Write-Host ("  Fake behaviour   : past the real size it {0}" -f $reason) }
    Write-Host ("  New partition    : {0}  {1}  {2}, label {3}" -f $vol.Letters, (Fmt $part), $fs, $vol.Label) -ForegroundColor Green
    if ($m) { Write-Host ("  Speed            : write {0:N1} MB/s, read {1:N1} MB/s" -f $m.WriteMBps, $m.ReadMBps) }
    if (-not $verified) {
        Write-Host '  Verdict          : usable, but not verified. Run option 1 if you want certainty.' -ForegroundColor Yellow
    } elseif ($m -and $m.WriteMBps -lt 3) {
        Write-Host '  Verdict          : works, but very slow. Fine for small, unimportant files only.' -ForegroundColor Yellow
    } else {
        Write-Host '  Verdict          : OK for unimportant files.' -ForegroundColor Green
    }
    Write-Host '=========================================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Phones and PCs will now show the real size.'
    if (-not $genuine) {
        Write-Host '  Do NOT format this stick from a phone, TV or camera: that rewrites the fake size.'
        Write-Host '  If it ever shows the fake size again, just run this tool again.'
        Write-Host '  Cheap fake flash wears out fast - keep a copy of anything that matters.'
    }
}

function Invoke-Fix($id, [bool]$quick) {
    if (-not (Confirm-Wipe $id)) { Write-Host '  Nothing was changed.' -ForegroundColor Green; return $false }
    Reset-ToRaw $id
    $p = Invoke-Probe $id
    if (-not $p.AllGood -and $p.KnownGood -lt 64MB) { throw 'The stick does not even hold 64 MB reliably. It is junk - throw it away.' }

    $m = $null; $real = [int64]$p.KnownGood; $verified = $false; $genuine = $false

    if ($quick) {
        if ($p.AllGood) {
            Write-Host ''
            Write-Host '  The quick probe cannot tell this stick apart from a genuine one. Use option 1 (full test).' -ForegroundColor Yellow
            return $true
        }
    } else {
        $upper = [int64]$p.FirstBadOffset
        if ($p.AllGood) { $upper = [int64]$p.Length }
        Write-Step ('Step 2/3 - exact measurement: writing and reading back up to {0}' -f (Fmt $upper))
        Write-Host '  Cheap sticks write at 3-15 MB/s, so ~30 GB takes about 1-3 hours. The ETA is shown live.'
        Write-Host '  You can leave it running. Press Esc to stop (you can still keep what was proven so far).'
        $dev = Open-Raw $id
        try { $m = [FakeUsb.Core]::Measure($dev, $upper) } finally { $dev.Dispose() }
        $real = [int64]$m.RealSize
        if ($m.Cancelled) {
            Write-Host ''
            Write-Host ("  Stopped. Proven good so far: {0}" -f (Fmt $real)) -ForegroundColor Yellow
            if ($real -lt 64MB) { Write-Host '  Too little to be useful. Run the tool again and let the test finish.'; return $true }
            $a = Read-Host ('  Create a partition of {0} (95% of what was proven)? [y/N]' -f (Fmt (Get-PartSize $real)))
            if ($a -notmatch '^[yY]') { Write-Host '  The stick is left blank. Run the tool again to finish.'; return $true }
        } else {
            $verified = $m.Verified
            if ($real -lt 64MB) { throw 'The stick does not even hold 64 MB reliably. It is junk - throw it away.' }
            $genuine = ($p.AllGood -and $m.WholeRangeClean -and $upper -ge $p.Length)
            if ($genuine) { Write-Host '  Every byte checked out: this stick is genuine.' -ForegroundColor Green }
            else { Write-Host ("  Real size measured: {0}" -f (Fmt $real)) -ForegroundColor Green }
        }
    }

    if ($genuine) { $part = [int64]$p.Length - 2MB } else { $part = Get-PartSize $real }
    $fs = Select-FileSystem $part
    $vol = New-RealPartition $id $part $fs $genuine
    Show-Report $id $p $m $real $part $vol $fs $verified $genuine
    return $true
}

function Show-ControllerInfo($id) {
    Write-Step 'Controller info (only needed for a firmware reflash)'
    Write-Host ("  Name    : {0}" -f $id.Name)
    Write-Host ("  VID:PID : {0}" -f $id.VidPid)
    Write-Host ("  Serial  : {0}" -f $id.Serial)
    Write-Host ''
    Write-Host '  Fakes often spoof these IDs. To find the real controller chip and its MPTool:'
    Write-Host '   1. Run ChipGenius or Flash Drive Information Extractor with the stick plugged in.'
    Write-Host '   2. Note the "Controller Part-Number" and the "Flash ID".'
    Write-Host '   3. Search them at https://flashboot.ru/iflash/ and https://www.usbdev.ru/'
    Write-Host '   4. Check every downloaded tool at https://www.virustotal.com before running it.'
    Write-Host '  Option 1 in this tool gives the same visible result without touching the firmware.'
}

function Select-UsbDisk {
    while ($true) {
        $disks = @(Get-UsbDisks)
        if ($disks.Count -eq 0) {
            Write-Host ''
            Write-Host '  No USB stick found. Plug it in, wait a few seconds, then press Enter (Q to quit).' -ForegroundColor Yellow
            $a = Read-Host ' '
            if ($a -match '^[qQ]') { return $null }
            continue
        }
        if ($Disk -ge 0) {
            if ($disks | Where-Object { $_.Number -eq $Disk }) { return (Get-Identity $Disk) }
            Write-Host "  Disk $Disk is not a USB data disk." -ForegroundColor Yellow
            $script:Disk = -1
        }
        Write-Host ''
        Write-Host '  USB disks found:'
        foreach ($d in $disks) {
            Write-Host ('   [{0}] {1}  |  reports {2}  |  VID:PID {3}  |  {4}' -f $d.Number, $d.FriendlyName, (Fmt ([int64]$d.Size)), (Get-VidPid $d.Number), (Get-DriveLetters $d.Number))
        }
        if ($disks.Count -eq 1) {
            $n = [int]$disks[0].Number
            $a = Read-Host "  Use disk $n? [Y/n]"
            if ($a -match '^[nN]') { return $null }
            return (Get-Identity $n)
        }
        $a = Read-Host '  Type the disk number to use (Q to quit)'
        if ($a -match '^[qQ]') { return $null }
        $num = -1
        if ([int]::TryParse($a.Trim(), [ref]$num) -and ($disks | Where-Object { $_.Number -eq $num })) { return (Get-Identity $num) }
        Write-Host '  That is not one of the listed USB disks.' -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------ main
$logDir = Split-Path -Parent $PSCommandPath
$logName = 'fake-usb-log-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmm')
$log = Join-Path $logDir $logName
try { Start-Transcript -Path $log -Append | Out-Null }
catch {
    $log = Join-Path ([Environment]::GetFolderPath('MyDocuments')) $logName
    try { Start-Transcript -Path $log -Append | Out-Null } catch { $log = $null }
}

try {
    Write-Host ''
    Write-Host '  ===================================================' -ForegroundColor Cyan
    Write-Host '   Fix fake USB stick - make it show its REAL size' -ForegroundColor Cyan
    Write-Host '  ===================================================' -ForegroundColor Cyan

    if (-not ('FakeUsb.Core' -as [type])) { Add-Type -TypeDefinition $CoreSource -Language CSharp -IgnoreWarnings }

    $id = Select-UsbDisk
    if ($id) {
        Write-Host ''
        Write-Host ("  Selected: disk {0} - {1}" -f $id.Number, $id.Name) -ForegroundColor Green
        Write-Host ("    Reports : {0}" -f (Fmt $id.Size))
        Write-Host ("    Serial  : {0}" -f $id.Serial)
        Write-Host ("    VID:PID : {0}" -f $id.VidPid)
        Write-Host ("    Letters : {0}" -f (Get-DriveLetters $id.Number))
        $done = $false
        while (-not $done) {
            Write-Host ''
            Write-Host '  What do you want to do?'
            Write-Host '    [1] Fix it - measure the exact real size, shrink and format  (recommended, 1-3 h)'
            Write-Host '    [2] Quick fix - estimate the size in minutes, shrink and format (not verified)'
            Write-Host '    [3] Controller info (VID/PID for a firmware reflash)'
            Write-Host '    [Q] Quit'
            $c = (Read-Host '  Choose').Trim()
            switch -Regex ($c) {
                '^1$'    { $done = [bool](Invoke-Fix $id $false) }
                '^2$'    { $done = [bool](Invoke-Fix $id $true) }
                '^3$'    { Show-ControllerInfo $id }
                '^[qQ]$' { $done = $true }
                default  { Write-Host '  Type 1, 2, 3 or Q.' -ForegroundColor Yellow }
            }
        }
    }
} catch {
    Write-Host ''
    Write-Host ('  ERROR: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($log) { try { Stop-Transcript | Out-Null } catch {} }
}

if ($log) { Write-Host ''; Write-Host "  Log saved to: $log" }
Write-Host ''
Read-Host '  Press Enter to close' | Out-Null
