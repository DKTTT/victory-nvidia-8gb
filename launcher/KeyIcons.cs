// (Neptune) Keyboard and mouse prompt icons for the title's `input_icons` movie, made at Play from the
// player's own data.rpf. A C# port of tools/gfx_input_icons.py (commit f47255b9b): the same
// output byte for byte for the same data.rpf and font. Read that file's header for the format: the retail movie
// (GFX v42, 28148 bytes, a zlib stream in data.rpf at 293433344) keeps every tag but its art (DefineShape3 and
// DefineSprite); each exported pad glyph sprite gets keyboard or mouse art drawn to the geometry of Leonida's
// approved icon set (gen_keys.mjs): rounded keycaps with a 10 px black border, lettering from a TrueType font's
// outlines, 6 px round strokes.
//
// The result is the player's own derived file (it carries the retail movie's AS3 bytecode): it is written to
// %LOCALAPPDATA%\Neptune and never belongs in the repository. No font ships with Neptune and nothing is
// downloaded: a system font is used (Fonts below). The keycap sizes are measured against the font used, as the
// tool's are: single letters sit in a 192-unit key at 108 units, which any bold sans fits; word keys grow
// with their text, and the stick keys scale their text to fit.
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace Neptune;

static class KeyIcons
{
    public const long RetailOffset = 293433344;
    const int RetailSize = 28148;
    const double Canvas = 64.0;          // px, the retail glyph canvas
    const double SourceH = 192.0;        // px, the approved icons' height
    const double K = Canvas / SourceH;   // approved px -> canvas px
    const double TW = 20.0;              // twips per px

    // Pad glyph number -> icon (see the Python tool: keys follow the stand-in pad of gameinput.rs)
    static readonly Dictionary<int, string> Buttons = new()
    {
        [4] = "up", [5] = "down", [6] = "left", [7] = "right",
        [8] = "arrows", [9] = "arrows", [10] = "updown", [11] = "leftright",
        [12] = "w", [13] = "s", [14] = "a", [15] = "d", [16] = "f",
        [17] = "wasd", [18] = "ws", [19] = "ad", [20] = "wasd",
        [21] = "mouse_up", [22] = "mouse_down", [23] = "mouse_left", [24] = "mouse_right",
        [25] = "h", [26] = "mouse", [27] = "mouse_updown", [28] = "mouse_leftright", [29] = "mouse",
        [30] = "enter", [31] = "backspace", [32] = "x", [33] = "tab",
        [34] = "q", [35] = "e", [36] = "z", [37] = "c",
        [38] = "esc", [39] = "v",
        [58] = "wasd", [59] = "mouse",
    };
    // every character the art writes
    const string Letters = "WSADFHXQEZCVENTERBACKTABESC/";

    static readonly byte[] Black = [0, 0, 0, 255];
    static readonly byte[] White = [255, 255, 255, 255];

    // ---- the system fonts tried, in order: the first that exists and has the letters ----
    static string[] Fonts()
    {
        if (OperatingSystem.IsWindows())
        {
            var dir = Environment.GetFolderPath(Environment.SpecialFolder.Fonts);
            if (dir.Length == 0) dir = @"C:\Windows\Fonts";
            return [Path.Combine(dir, "ARIALNB.TTF"), Path.Combine(dir, "seguisb.ttf"), Path.Combine(dir, "arialbd.ttf")];
        }
        return ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf", "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
                "/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf", "/usr/share/fonts/TTF/LiberationSans-Bold.ttf"];
    }
    static Font? Usable(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var f = new Font(path);
            foreach (var c in Letters) { var g = f.Glyph(c); if (g == 0) return null; f.Contours(g); }
            return f;
        }
        catch { return null; }
    }

    // ---- at Play: the file for VICTORY_REPLACE_STREAMS, made when missing or out of date; null (and one log
    //      line) when it can't be. Fast (tens of ms when made, a few file checks otherwise); call off the UI thread.
    public static string? Ensure(string gameDir, List<string> notes)
    {
        try
        {
            var rpf = new FileInfo(Path.Combine(gameDir, "data.rpf"));
            if (!rpf.Exists) { notes.Add($"键盘提示图标：游戏所在的 {gameDir} 旁没有 data.rpf：游戏将显示手柄按键"); return null; }
            string? fontPath = null; Font? font = null;
            foreach (var p in Fonts()) if (Usable(p) is Font f) { fontPath = p; font = f; break; }
            if (font == null) { notes.Add($"键盘提示图标：以下字体均不存在，无法显示字母（{string.Join("、", Fonts())}）：游戏将显示手柄按键"); return null; }
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Neptune");
            var gfx = Path.Combine(dir, "input_icons_kbm.gfx");
            var side = Path.Combine(dir, "input_icons_kbm.txt");
            // what it was made from: data.rpf's size and time, and the font
            var from = $"{rpf.Length} {rpf.LastWriteTimeUtc.Ticks} {fontPath}";
            var exe = Environment.ProcessPath;
            var exeTime = exe != null && File.Exists(exe) ? File.GetLastWriteTimeUtc(exe) : DateTime.MinValue;
            if (File.Exists(gfx) && File.Exists(side) && File.ReadAllText(side).Trim() == from && File.GetLastWriteTimeUtc(gfx) >= exeTime)
            {
                notes.Add($"键盘提示图标：{gfx}（由你的 data.rpf 制作，字体 {Path.GetFileName(fontPath)}）");
                return gfx;
            }
            byte[] retail;
            try { retail = ReadRetail(rpf.FullName); }
            catch (Exception e) { notes.Add($"键盘提示图标：data.rpf 在偏移 {RetailOffset} 处没有正式版 input_icons 影片（{e.Message}；游戏版本不同？）：游戏将显示手柄按键"); return null; }
            var movie = Build(retail, font!, RetailSize);
            Directory.CreateDirectory(dir);
            var tmp = gfx + ".new";
            File.WriteAllBytes(tmp, movie);
            File.Move(tmp, gfx, true);
            File.WriteAllText(side, from);
            notes.Add($"键盘提示图标：已由你的 data.rpf 制作 {gfx}（字体 {Path.GetFileName(fontPath)}，{movie.Length} 字节）");
            return gfx;
        }
        catch (Exception e) { notes.Add($"键盘提示图标未生成（{e.Message}）：游戏将显示手柄按键"); return null; }
    }

    // the retail movie: a zlib stream at RetailOffset, inflated (at most 1 MB from 256 KB read)
    public static byte[] ReadRetail(string rpf)
    {
        var chunk = new byte[1 << 18];
        int got = 0;
        using (var f = File.OpenRead(rpf))
        {
            f.Seek(RetailOffset, SeekOrigin.Begin);
            for (int n; got < chunk.Length && (n = f.Read(chunk, got, chunk.Length - got)) > 0;) got += n;
        }
        using var z = new ZLibStream(new MemoryStream(chunk, 0, got), CompressionMode.Decompress);
        var outp = new MemoryStream();
        var buf = new byte[1 << 16];
        for (int n; outp.Length < (1 << 20) && (n = z.Read(buf, 0, buf.Length)) > 0;) outp.Write(buf, 0, n);
        var retail = outp.ToArray();
        if (retail.Length > 1 << 20) retail = retail[..(1 << 20)];
        if (retail.Length < 9 || retail[0] != 'G' || retail[1] != 'F' || retail[2] != 'X' || BitConverter.ToUInt32(retail, 4) != retail.Length)
            throw new InvalidDataException("该偏移处没有 GFX 影片");
        return retail;
    }

    // ---- TrueType ----
    sealed class Font
    {
        readonly byte[] d;
        readonly Dictionary<string, int> t = new();
        public readonly int Upm, Ascender, Descender;
        readonly bool longLoca;
        readonly int nHmetrics, cmap;
        static int U16(byte[] d, int o) => (d[o] << 8) | d[o + 1];
        static int S16(byte[] d, int o) => (short)((d[o] << 8) | d[o + 1]);
        static long U32(byte[] d, int o) => ((long)d[o] << 24) | ((long)d[o + 1] << 16) | ((long)d[o + 2] << 8) | d[o + 3];

        public Font(string path)
        {
            d = File.ReadAllBytes(path);
            int n = U16(d, 4);
            for (int i = 0; i < n; i++)
            {
                var tag = Encoding.Latin1.GetString(d, 12 + i * 16, 4);
                t[tag] = (int)U32(d, 12 + i * 16 + 8);
            }
            int head = t["head"];
            Upm = U16(d, head + 18);
            longLoca = S16(d, head + 50) != 0;
            int hhea = t["hhea"];
            Ascender = S16(d, hhea + 4); Descender = S16(d, hhea + 6);
            nHmetrics = U16(d, hhea + 34);
            cmap = Cmap();
        }
        int Cmap()
        {
            int b = t["cmap"];
            for (int i = 0; i < U16(d, b + 2); i++)
            {
                int pid = U16(d, b + 4 + i * 8), eid = U16(d, b + 4 + i * 8 + 2);
                int off = (int)U32(d, b + 4 + i * 8 + 4);
                if (((pid == 3 && eid == 1) || (pid == 0 && eid == 3) || (pid == 0 && eid == 4)) && U16(d, b + off) == 4) return b + off;
            }
            throw new InvalidDataException("字体没有 Unicode format-4 cmap");
        }
        public int Glyph(char ch)
        {
            int sub = cmap, seg2 = U16(d, sub + 6), n = seg2 / 2, c = ch;
            for (int i = 0; i < n; i++)
            {
                int end = U16(d, sub + 14 + 2 * i);
                if (c <= end)
                {
                    int start = U16(d, sub + 16 + seg2 + 2 * i), delta = S16(d, sub + 16 + 2 * seg2 + 2 * i), range = U16(d, sub + 16 + 3 * seg2 + 2 * i);
                    if (c < start) break;
                    if (range == 0) return (c + delta) & 0xFFFF;
                    int g = U16(d, sub + 16 + 3 * seg2 + 2 * i + range + 2 * (c - start));
                    return g != 0 ? (g + delta) & 0xFFFF : 0;
                }
            }
            throw new InvalidDataException($"字体缺少“{ch}”");
        }
        public int Advance(int gid) => U16(d, t["hmtx"] + 4 * Math.Min(gid, nHmetrics - 1));

        // [[(x, y, on_curve)]] in font units, y up
        public List<List<(int x, int y, bool on)>> Contours(int gid)
        {
            int loca = t["loca"], glyf = t["glyf"];
            long a, b;
            if (longLoca) { a = U32(d, loca + 4 * gid); b = U32(d, loca + 4 * gid + 4); }
            else { a = U16(d, loca + 2 * gid) * 2L; b = U16(d, loca + 2 * gid + 2) * 2L; }
            var outp = new List<List<(int, int, bool)>>();
            if (a == b) return outp;
            int off = glyf + (int)a;
            int n = S16(d, off);
            if (n < 0) throw new InvalidDataException($"不支持复合字形 {gid}");
            if (n == 0) throw new InvalidDataException($"字形 {gid} 没有轮廓");
            var ends = new int[n];
            for (int i = 0; i < n; i++) ends[i] = U16(d, off + 10 + 2 * i);
            int p = off + 10 + 2 * n;
            int count = ends[^1] + 1;
            p += 2 + U16(d, p);
            var flags = new List<int>();
            while (flags.Count < count)
            {
                int f = d[p++];
                flags.Add(f);
                if ((f & 8) != 0) { int r = d[p++]; for (int k = 0; k < r; k++) flags.Add(f); }
            }
            var coords = new int[2][];
            int ci = 0;
            foreach (var (shrt, same) in new[] { (2, 16), (4, 32) })
            {
                int v = 0; var vals = new int[count];
                for (int i = 0; i < count; i++)
                {
                    int f = flags[i];
                    if ((f & shrt) != 0) { v += (f & same) != 0 ? d[p] : -d[p]; p++; }
                    else if ((f & same) == 0) { v += S16(d, p); p += 2; }
                    vals[i] = v;
                }
                coords[ci++] = vals;
            }
            int s = 0;
            foreach (var e in ends)
            {
                var c = new List<(int, int, bool)>();
                for (int i = s; i <= e; i++) c.Add((coords[0][i], coords[1][i], (flags[i] & 1) != 0));
                outp.Add(c);
                s = e + 1;
            }
            return outp;
        }
    }

    // ---- geometry: contours are (start, [L p | Q ctrl p]) in canvas px ----
    readonly record struct P(double X, double Y);
    readonly record struct Edge(bool Quad, P A, P B)
    {
        public P End => Quad ? B : A;
        public static Edge L(P p) => new(false, p, default);
        public static Edge Q(P c, P p) => new(true, c, p);
    }
    sealed record Contour(P Start, List<Edge> Edges);
    sealed record Layer(byte[]? Fill, (double W, byte[] C)? Line, List<Contour> Contours);

    static double Radians(double deg) => deg * (Math.PI / 180.0);

    // quadratic segments for a circular arc, angles in degrees, y down
    static List<Edge> Arc(double cx, double cy, double r, double a0, double a1)
    {
        int n = Math.Max(1, (int)Math.Ceiling(Math.Abs(a1 - a0) / 45.0));
        double step = (a1 - a0) / n;
        var edges = new List<Edge>();
        for (int i = 0; i < n; i++)
        {
            double t0 = Radians(a0 + step * i), t1 = Radians(a0 + step * (i + 1));
            double tm = (t0 + t1) / 2;
            double rc = r / Math.Cos((t1 - t0) / 2);
            edges.Add(Edge.Q(new P(cx + rc * Math.Cos(tm), cy + rc * Math.Sin(tm)), new P(cx + r * Math.Cos(t1), cy + r * Math.Sin(t1))));
        }
        return edges;
    }

    // clockwise on screen (y down): the retail fill convention for outer contours
    static Contour RoundedRect(double x, double y, double w, double h, double r)
    {
        r = Math.Min(r, Math.Min(w / 2, h / 2));
        var start = new P(x + r, y);
        var e = new List<Edge> { Edge.L(new P(x + w - r, y)) };
        e.AddRange(Arc(x + w - r, y + r, r, -90, 0));
        e.Add(Edge.L(new P(x + w, y + h - r)));
        e.AddRange(Arc(x + w - r, y + h - r, r, 0, 90));
        e.Add(Edge.L(new P(x + r, y + h)));
        e.AddRange(Arc(x + r, y + h - r, r, 90, 180));
        e.Add(Edge.L(new P(x, y + r)));
        e.AddRange(Arc(x + r, y + r, r, 180, 270));
        return new Contour(start, e);
    }

    static Contour Polyline(List<P> pts) => new(pts[0], pts.Skip(1).Select(Edge.L).ToList());

    static List<Contour> Transform(List<Contour> contours, double sx, double sy, double tx, double ty)
    {
        P F(P p) => new(p.X * sx + tx, p.Y * sy + ty);
        return contours.Select(c => new Contour(F(c.Start), c.Edges.Select(e => e.Quad ? Edge.Q(F(e.A), F(e.B)) : Edge.L(F(e.A))).ToList())).ToList();
    }

    static readonly Regex SvgToken = new(@"[MLHV]|-?\d+(?:\.\d+)?");
    // the subset gen_keys.mjs uses: M, L, H, V (absolute)
    static List<Contour> SvgPath(string d)
    {
        var toks = SvgToken.Matches(d).Select(m => m.Value).ToList();
        var outp = new List<List<P>>(); List<P>? cur = null;
        int i = 0; string last = "L"; double x = 0, y = 0;
        static double Num(string s) => double.Parse(s, System.Globalization.CultureInfo.InvariantCulture);
        while (i < toks.Count)
        {
            var c = toks[i];
            if (c is "M" or "L" or "H" or "V") i++; else c = last;
            if (c == "M")
            {
                x = Num(toks[i]); y = Num(toks[i + 1]); i += 2;
                cur = [new P(x, y)]; outp.Add(cur); last = "L"; continue;
            }
            if (c == "L") { x = Num(toks[i]); y = Num(toks[i + 1]); i += 2; }
            else if (c == "H") { x = Num(toks[i]); i++; }
            else { y = Num(toks[i]); i++; }
            cur!.Add(new P(x, y));
            last = c;
        }
        return outp.Select(Polyline).ToList();
    }

    // ---- layers ----
    // glyph outlines placed as SVG would: text-anchor middle (or start), letter-spacing after every glyph,
    // dominant-baseline central = y + (ascender + descender) / 2 em
    static Layer TextLayer(Font font, string text, double x, double y, double size, double spacing, bool middle = true)
    {
        double s = size / font.Upm;
        var gids = text.Select(font.Glyph).ToList();
        double width = 0;
        foreach (var g in gids) width += font.Advance(g) * s + spacing;
        double pen = middle ? x - width / 2 : x;
        double bas = y + (font.Ascender + font.Descender) / 2.0 * s;
        var contours = new List<Contour>();
        foreach (var g in gids)
        {
            foreach (var c in font.Contours(g)) contours.Add(GlyphContour(c, s, pen, bas));
            pen += font.Advance(g) * s + spacing;
        }
        return new Layer(Black, null, contours);
    }

    static Contour GlyphContour(List<(int x, int y, bool on)> pts, double s, double dx, double dy)
    {
        var p0 = pts.Select(q => (x: q.x * s + dx, y: -q.y * s + dy, on: q.on)).ToList();
        int k = p0.FindIndex(q => q.on);
        List<(double x, double y, bool on)> pp;
        if (k < 0)
        {
            var (a, b) = (p0[0], p0[1]);
            pp = [((a.x + b.x) / 2, (a.y + b.y) / 2, true), .. p0.Skip(1), p0[0]];
        }
        else pp = [.. p0.Skip(k), .. p0.Take(k)];
        var start = new P(pp[0].x, pp[0].y);
        var edges = new List<Edge>();
        int n = pp.Count, i = 1;
        while (i <= n)
        {
            var p = pp[i % n];
            if (p.on) { edges.Add(Edge.L(new P(p.x, p.y))); i++; continue; }
            var q = pp[(i + 1) % n];
            var end = q.on ? new P(q.x, q.y) : new P((p.x + q.x) / 2, (p.y + q.y) / 2);
            edges.Add(Edge.Q(new P(p.x, p.y), end));
            i += q.on ? 2 : 1;
        }
        if (edges.Count > 0 && edges[^1].End != start) edges.Add(Edge.L(start));
        return new Contour(start, edges);
    }

    // gen_keys.mjs keycap(): rect 8,8,(w-16)x176 rx 36, white, 10 px black stroke
    static Layer Keycap(double w) => new(White, (10.0, Black), [RoundedRect(8, 8, w - 16, SourceH - 16, 36)]);

    static Layer Strokes(string[] ds, double width = 6.0, double tx = 0.0, double ty = 0.0, double scale = 1.0)
    {
        var contours = new List<Contour>();
        foreach (var d in ds) contours.AddRange(Transform(SvgPath(d), scale, scale, tx, ty));
        return new Layer(null, (width * scale, Black), contours);
    }

    // gen_keys.mjs I{} paths, 40x40 boxes
    static readonly Dictionary<string, string[]> Icon = new()
    {
        ["up"] = ["M20 4 V36", "M20 4 L8 16", "M20 4 L32 16"],
        ["down"] = ["M20 36 V4", "M20 36 L8 24", "M20 36 L32 24"],
        ["left"] = ["M4 20 H36", "M4 20 L16 8", "M4 20 L16 32"],
        ["right"] = ["M36 20 H4", "M36 20 L24 8", "M36 20 L24 32"],
        ["backspace"] = ["M36 6 V34", "M30 20 H6", "M6 20 L16 10", "M6 20 L16 30"],
        ["tab"] = ["M4 6 V34", "M10 20 H36", "M36 20 L24 10", "M36 20 L24 30"],
        ["caps"] = ["M20 2 V22", "M20 2 L9 13", "M20 2 L31 13", "M8 32 H32"],
        ["del"] = ["M4 20 H26", "M26 20 L16 10", "M26 20 L16 30", "M32 6 V34"],
        ["space"] = ["M0 6 V34 H40 V6"],
        ["enter"] = ["M4 4 H34 V28 H2", "M2 28 L14 18", "M2 28 L14 38"],
    };

    static (double, List<Layer>) GlyphKey(Font font, string text, double w = 192.0, double size = 108.0, double dy = 0.0)
    {
        double spacing = text.Length > 1 ? 0.6 : 0.0;
        return (w, [Keycap(w), TextLayer(font, text, w / 2, 96 + dy, size, spacing)]);
    }

    const double WordSize = 88.0, WordSpacing = 1.0, WordMargin = 28.0, WordGap = 14.0, MarkScale = 1.1;

    static double TextWidth(Font font, string text, double size, double spacing)
    {
        double s = size / font.Upm, sum = 0;
        foreach (var c in text) sum += font.Advance(font.Glyph(c)) * s;
        return sum + spacing * (text.Length - 1);
    }

    // a key as wide as its text and mark; `square` keeps it to the 64 px slot and sets the text smaller instead
    static (double, List<Layer>) WordKey(Font font, string text, string? icon = null, bool square = false)
    {
        double size = WordSize;
        double tw = TextWidth(font, text, size, WordSpacing);
        double mark = icon != null ? 40 * MarkScale : 0.0;
        double room = SourceH - 2 * WordMargin - 20;
        if (square && tw > room) { size *= room / tw; tw = TextWidth(font, text, size, WordSpacing); }
        double inner = tw + (icon != null ? WordGap + mark : 0.0);
        double w = square ? SourceH : Math.Max(SourceH, inner + 2 * WordMargin + 20);
        double left = (w - inner) / 2;
        var layers = new List<Layer> { Keycap(w), TextLayer(font, text, left, 96, size, WordSpacing, middle: false) };
        if (icon != null) layers.Add(Strokes(Icon[icon], tx: left + tw + WordGap, ty: (SourceH - mark) / 2, scale: MarkScale));
        return (w, layers);
    }

    static (double, List<Layer>) SymbolKey(string icon, double w = 192.0, double scale = 1.35)
    {
        double box = 40 * scale;
        return (w, [Keycap(w), Strokes(Icon[icon], tx: (w - box) / 2, ty: (SourceH - box) / 2, scale: scale)]);
    }

    // two arrow strokes side by side (composites for the D-pad and stick pairs)
    static (double, List<Layer>) PairKey(string a, string b, double w = 192.0, double scale = 1.0)
    {
        double box = 40 * scale, gap = 12;
        double x0 = (w - 2 * box - gap) / 2, y0 = (SourceH - box) / 2;
        return (w, [Keycap(w), Strokes(Icon[a], tx: x0, ty: y0, scale: scale), Strokes(Icon[b], tx: x0 + box + gap, ty: y0, scale: scale)]);
    }

    // four arrows in a cross: the whole D-pad
    static (double, List<Layer>) ArrowsKey(double w = 192.0)
    {
        double s = 0.8, box = 40 * s, cx = w / 2, cy = SourceH / 2;
        var at = new (string, double, double)[]
        {
            ("up", cx - box / 2, cy - box - 2), ("down", cx - box / 2, cy + 2),
            ("left", cx - box - 6 - box / 2, cy - box / 2), ("right", cx + box / 2 + 6, cy - box / 2),
        };
        var layers = new List<Layer> { Keycap(w) };
        foreach (var (name, x, y) in at) layers.Add(Strokes(Icon[name], tx: x, ty: y, scale: s));
        return (w, layers);
    }

    static List<Contour> Svg2(params string[] ds) { var l = new List<Contour>(); foreach (var d in ds) l.AddRange(SvgPath(d)); return l; }

    // gen_keys.mjs mouseKey(): body 60x108 rx 28 at the key centre (shifted for arrows)
    static (double, List<Layer>) MouseKey(string mode)
    {
        double w = 192.0;
        var (sx, sy) = mode switch { "up" => (0, 16), "down" => (0, -16), "left" => (18, 0), "right" => (-18, 0), _ => (0, 0) };
        double cx = 96 + sx, cy = 98 + sy;
        var layers = new List<Layer> { Keycap(w) };
        if (mode is "lclick" or "rclick")
        {
            P start; List<Edge> e;
            if (mode == "lclick")
            {
                start = new P(0, -18);
                e = [Edge.L(new P(-30, -18)), Edge.L(new P(-30, -26)), .. Arc(-2, -26, 28, 180, 270), Edge.L(new P(0, -54)), Edge.L(new P(0, -18))];
            }
            else
            {
                start = new P(0, -54);
                e = [Edge.L(new P(2, -54)), .. Arc(2, -26, 28, 270, 360), Edge.L(new P(30, -18)), Edge.L(new P(0, -18)), Edge.L(new P(0, -54))];
            }
            layers.Add(new Layer(Black, null, Transform([new Contour(start, e)], 1, 1, cx, cy)));
        }
        layers.Add(new Layer(null, (5.0, Black), Transform([RoundedRect(-30, -54, 60, 108, 28)], 1, 1, cx, cy)));
        layers.Add(new Layer(null, (4.0, Black), Transform(Svg2("M0 -54 V-18", "M-30 -18 H30"), 1, 1, cx, cy)));
        if (mode == "middle") layers.Add(new Layer(Black, null, Transform([RoundedRect(-8, -46, 16, 24, 5)], 1, 1, cx, cy)));
        else if (mode == "scrollup") layers.Add(new Layer(null, (5.0, Black), Transform(Svg2("M0 -50 V-28", "M0 -50 L-8 -40", "M0 -50 L8 -40"), 1, 1, cx, cy)));
        else if (mode == "scrolldown") layers.Add(new Layer(null, (5.0, Black), Transform(Svg2("M0 -24 V-46", "M0 -24 L-8 -34", "M0 -24 L8 -34"), 1, 1, cx, cy)));
        else layers.Add(new Layer(White, (4.0, Black), Transform([RoundedRect(-7, -44, 14, 20, 5)], 1, 1, cx, cy)));
        var arrow = new Dictionary<string, (double x, double y, string[] ds)>
        {
            ["up"] = (96, 30, ["M0 22 V0", "M0 0 L-10 12", "M0 0 L10 12"]),
            ["down"] = (96, 162, ["M0 -22 V0", "M0 0 L-10 -12", "M0 0 L10 -12"]),
            ["left"] = (30, 96, ["M22 0 H0", "M0 0 L12 -10", "M0 0 L12 10"]),
            ["right"] = (162, 96, ["M-22 0 H0", "M0 0 L-12 -10", "M0 0 L-12 10"]),
        };
        string[] parts = mode switch { "updown" => ["up", "down"], "leftright" => ["left", "right"], _ => [mode] };
        foreach (var part in parts)
        {
            if (!arrow.TryGetValue(part, out var a)) continue;
            var (x, y, ds) = a;
            if (mode is "updown" or "leftright")
            {
                // composites keep the body centred and use the outer margins
                (x, y) = part switch { "up" => (96, 20), "down" => (96, 172), "left" => (26, 96), _ => (166, 96) };
                if (part == "up") ds = ["M0 14 V0", "M0 0 L-8 9", "M0 0 L8 9"];
                else if (part == "down") ds = ["M0 -14 V0", "M0 0 L-8 -9", "M0 0 L8 -9"];
            }
            var contours = new List<Contour>();
            foreach (var d in ds) contours.AddRange(Transform(SvgPath(d), 1, 1, x, y));
            layers.Add(new Layer(null, (6.0, Black), contours));
        }
        return (w, layers);
    }

    static (double, List<Layer>) IconLayers(Font font, string name)
    {
        if (name.Length == 1 && name[0] is >= 'a' and <= 'z') return GlyphKey(font, name.ToUpperInvariant());
        switch (name)
        {
            case "enter": return WordKey(font, "ENTER", "enter");
            case "backspace": return WordKey(font, "BACK", "backspace");
            case "tab": return WordKey(font, "TAB", "tab");
            case "esc": return WordKey(font, "ESC");
            case "up": case "down": case "left": case "right": return SymbolKey(name);
            case "arrows": return ArrowsKey();
            case "updown": return PairKey("up", "down");
            case "leftright": return PairKey("left", "right");
            case "wasd": return WordKey(font, "WASD", square: true);
            case "ws": return WordKey(font, "W/S", square: true);
            case "ad": return WordKey(font, "A/D", square: true);
            case "ijkl": return WordKey(font, "IJKL", square: true);
            case "ik": return WordKey(font, "I/K", square: true);
            case "jl": return WordKey(font, "J/L", square: true);
        }
        if (name.StartsWith("mouse"))
        {
            var mode = name switch
            {
                "mouse" => "plain", "mouse_up" => "up", "mouse_down" => "down", "mouse_left" => "left", "mouse_right" => "right",
                "mouse_updown" => "updown", "mouse_leftright" => "leftright", "mouse_left_click" => "lclick", "mouse_right_click" => "rclick",
                "mouse_middle" => "middle", "mouse_scroll_up" => "scrollup", "mouse_scroll_down" => "scrolldown",
                _ => throw new InvalidDataException($"没有 {name} 的图形"),
            };
            return MouseKey(mode);
        }
        throw new InvalidDataException($"没有 {name} 的图形");
    }

    // ---- SWF encoding ----
    sealed class BitWriter
    {
        readonly List<bool> bits = new();
        public void U(long v, int n) { for (int i = n - 1; i >= 0; i--) bits.Add(((v >> i) & 1) != 0); }
        public byte[] Bytes()
        {
            var o = new byte[(bits.Count + 7) / 8];
            for (int i = 0; i < bits.Count; i++) if (bits[i]) o[i >> 3] |= (byte)(0x80 >> (i & 7));
            return o;
        }
    }
    static int BitLength(long v) { int n = 0; while (v > 0) { n++; v >>= 1; } return n; }
    // bits for a signed value set (at least 2)
    static int SBits(params long[] values) => Math.Max(2, values.Max(v => BitLength(v >= 0 ? v : -v - 1) + 1));
    static int UBits(long v) => Math.Max(1, BitLength(v));
    static long R(double v) => (long)Math.Round(v, MidpointRounding.ToEven);

    static byte[] RectBytes(long xmin, long xmax, long ymin, long ymax)
    {
        int nb = SBits(xmin, xmax, ymin, ymax);
        var w = new BitWriter();
        w.U(nb, 5);
        foreach (var v in new[] { xmin, xmax, ymin, ymax }) w.U(v, nb);
        return w.Bytes();
    }

    static void LE16(List<byte> o, int v) { o.Add((byte)v); o.Add((byte)(v >> 8)); }

    // DefineShape3 for one layer, coordinates mapped canvas px = (approved px * sx + tx)
    static byte[] ShapeTag(int shapeId, Layer layer, double sx, double tx)
    {
        (long, long) ToTw(P p) => (R((p.X * sx + tx) * TW), R(p.Y * K * TW));
        var pts = new List<(long x, long y)>();
        foreach (var c in layer.Contours) pts.Add(ToTw(c.Start));
        foreach (var c in layer.Contours) foreach (var e in c.Edges) { pts.Add(ToTw(e.A)); if (e.Quad) pts.Add(ToTw(e.B)); }
        long pad = layer.Line is { } ln ? (long)Math.Ceiling(ln.W * K * TW / 2) + 1 : 1;
        var o = new List<byte>();
        LE16(o, shapeId);
        o.AddRange(RectBytes(pts.Min(p => p.x) - pad, pts.Max(p => p.x) + pad, pts.Min(p => p.y) - pad, pts.Max(p => p.y) + pad));
        bool fills = layer.Fill != null, lines = layer.Line != null;
        o.Add((byte)(fills ? 1 : 0));
        if (fills) { o.Add(0); o.AddRange(layer.Fill!); }
        o.Add((byte)(lines ? 1 : 0));
        if (lines) { LE16(o, (int)Math.Max(1, R(layer.Line!.Value.W * K * TW))); o.AddRange(layer.Line.Value.C); }
        int nfb = UBits(fills ? 1 : 0), nlb = UBits(lines ? 1 : 0);
        var w = new BitWriter();
        w.U(nfb, 4); w.U(nlb, 4);
        bool first = true;
        foreach (var c in layer.Contours)
        {
            var (x, y) = ToTw(c.Start);
            // StyleChange: move (+ the styles on the first record)
            w.U(0, 1);
            w.U(0, 1);                              // new styles
            w.U(first && lines ? 1 : 0, 1);         // line style
            w.U(0, 1);                              // fill1
            w.U(first && fills ? 1 : 0, 1);         // fill0 (retail convention)
            w.U(1, 1);                              // move
            int nb = SBits(x, y);
            w.U(nb, 5); w.U(x, nb); w.U(y, nb);
            if (first && fills) w.U(1, nfb);
            if (first && lines) w.U(1, nlb);
            first = false;
            long cx = x, cy = y;
            foreach (var e in c.Edges)
            {
                if (!e.Quad)
                {
                    var (ax, ay) = ToTw(e.A);
                    long dx = ax - cx, dy = ay - cy;
                    if (dx == 0 && dy == 0) continue;
                    nb = SBits(dx, dy);
                    w.U(1, 1); w.U(1, 1); w.U(nb - 2, 4);
                    if (dx != 0 && dy != 0) { w.U(1, 1); w.U(dx, nb); w.U(dy, nb); }
                    else { w.U(0, 1); w.U(dx == 0 ? 1 : 0, 1); w.U(dx == 0 ? dy : dx, nb); }
                    cx = ax; cy = ay;
                }
                else
                {
                    var (qx, qy) = ToTw(e.A);
                    var (ax, ay) = ToTw(e.B);
                    long[] v = [qx - cx, qy - cy, ax - qx, ay - qy];
                    if (v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0) continue;
                    nb = SBits(v);
                    w.U(1, 1); w.U(0, 1); w.U(nb - 2, 4);
                    foreach (var cv in v) w.U(cv, nb);
                    cx = ax; cy = ay;
                }
            }
        }
        w.U(0, 6);   // EndShapeRecord
        o.AddRange(w.Bytes());
        return Tag(32, o.ToArray());
    }

    static byte[] Tag(int code, byte[] payload)
    {
        var o = new List<byte>();
        if (payload.Length < 0x3F && code != 39) LE16(o, (code << 6) | payload.Length);
        else { LE16(o, (code << 6) | 0x3F); o.AddRange(BitConverter.GetBytes((uint)payload.Length)); }
        o.AddRange(payload);
        return o.ToArray();
    }

    static List<(int code, byte[] payload, byte[] raw)> Tags(byte[] b, int pos)
    {
        var list = new List<(int, byte[], byte[])>();
        while (pos + 2 <= b.Length)
        {
            int h = b[pos] | (b[pos + 1] << 8);
            int code = h >> 6, ln = h & 0x3F, start = pos;
            pos += 2;
            if (ln == 0x3F) { ln = (int)BitConverter.ToUInt32(b, pos); pos += 4; }
            int stop = Math.Min(b.Length, pos + ln);
            list.Add((code, b[pos..stop], b[start..stop]));
            pos += ln;
            if (code == 0) break;
        }
        return list;
    }

    // ExportAssets: (character id, name), in order
    static List<(int id, string name)> ExportsOf(byte[] p)
    {
        int n = p[0] | (p[1] << 8), at = 2;
        var o = new List<(int, string)>();
        for (int i = 0; i < n; i++)
        {
            int cid = p[at] | (p[at + 1] << 8); at += 2;
            int e = Array.IndexOf(p, (byte)0, at);
            var name = Encoding.Latin1.GetString(p, at, e - at);
            int k = o.FindIndex(x => x.Item1 == cid);
            if (k >= 0) o[k] = (cid, name); else o.Add((cid, name));   // as a Python dict
            at = e + 1;
        }
        return o;
    }

    // a prompt row has a fixed 64x64 slot per glyph; a key wider than the slot is centred in the span around it
    const double SlotBefore = 33.0, SlotAfter = 50.0;
    static double SlotOffset(double width) => Math.Min(0.0, (Canvas + SlotAfter - SlotBefore) / 2 - width / 2);

    static byte[] Build(byte[] retail, Font font, int? size)
    {
        int headLen = 8 + ((5 + (retail[8] >> 3) * 4 + 7) / 8) + 4;
        var all = Tags(retail, headLen);
        var exports = new List<(int id, string name)>();
        foreach (var (code, pl, _) in all) if (code == 56) exports = ExportsOf(pl);
        var spriteHeader = new Dictionary<int, int>();
        int maxId = 0;
        foreach (var (code, pl, _) in all)
            if (code is 32 or 39)
            {
                int cid = pl[0] | (pl[1] << 8);
                maxId = Math.Max(maxId, cid);
                if (code == 39) spriteHeader[cid] = pl[2] | (pl[3] << 8);
            }
        var missing = exports.Where(x => !spriteHeader.ContainsKey(x.id)).ToList();
        if (missing.Count > 0) throw new InvalidDataException("存在非精灵导出：" + string.Join("、", missing.Select(x => x.id)));
        int nextId = maxId + 1;
        var art = new Dictionary<int, byte[]>();
        foreach (var (cid, name) in exports)
        {
            int n = int.Parse(name[(name.LastIndexOf('_') + 1)..], System.Globalization.CultureInfo.InvariantCulture);
            if (!Buttons.TryGetValue(n, out var button)) throw new InvalidDataException($"没有 {name} 的键盘图标");
            var (w, layers) = IconLayers(font, button);
            double sx = K, tx = SlotOffset(w * K);
            var shapes = new List<byte>(); var places = new List<byte>();
            int depth = 1;
            foreach (var layer in layers)
            {
                shapes.AddRange(ShapeTag(nextId, layer, sx, tx));
                places.AddRange(Tag(26, [0x06, (byte)depth, (byte)(depth >> 8), (byte)nextId, (byte)(nextId >> 8), 0]));
                nextId++; depth++;
            }
            var sp = new List<byte>();
            LE16(sp, cid); LE16(sp, spriteHeader[cid]);
            sp.AddRange(places); sp.AddRange(Tag(0, []));
            shapes.AddRange(Tag(39, sp.ToArray()));
            art[cid] = shapes.ToArray();
        }
        var body = new List<byte>();
        bool placed = false;
        foreach (var (code, _, raw) in all)
        {
            if (code is 32 or 39)
            {
                if (!placed) { foreach (var (cid, _) in exports) body.AddRange(art[cid]); placed = true; }
                continue;
            }
            body.AddRange(raw);
        }
        var stage = retail[8..headLen];
        long total = 8 + stage.Length + body.Count;
        if (size is int sz)
        {
            if (total > sz) throw new InvalidDataException($"影片为 {total} 字节，超过游戏可读取的 {sz}");
            body.AddRange(new byte[sz - total]);
            total = sz;
        }
        var o = new List<byte> { (byte)'G', (byte)'F', (byte)'X', retail[3] };
        o.AddRange(BitConverter.GetBytes((uint)total));
        o.AddRange(stage);
        o.AddRange(body);
        return o.ToArray();
    }

    // for a check against the Python tool: the movie made from this data.rpf with this font
    public static byte[] BuildFrom(string rpf, string fontPath) => Build(ReadRetail(rpf), new Font(fontPath), RetailSize);
}
