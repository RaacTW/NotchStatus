import Cocoa
import SwiftUI
import Combine
import UserNotifications

// MARK: - Dil (varsayılan İngilizce, menüden Türkçe) --------------------------
var appLang = UserDefaults.standard.string(forKey: "lang") ?? "en"   // herkeste EN başlar
func L(_ en: String, _ tr: String) -> String { appLang == "tr" ? tr : en }
func locLabel(_ s: String) -> String {   // python'un yazdığı durum etiketini çevir (araç adları olduğu gibi kalır)
    if appLang == "en" { return s }
    switch s { case "Thinking": return "Düşünüyor"; case "Working": return "Çalışıyor"; case "Ready": return "Hazır"; default: return s }
}

// MARK: - Çentik geometrisi ---------------------------------------------------

func notchScreen() -> NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first }
struct NotchMetrics {
    let notchWidth: CGFloat; let notchHeight: CGFloat
    init(screen: NSScreen) {
        let t = screen.safeAreaInsets.top; notchHeight = t > 0 ? t : 32
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { notchWidth = max(120, r.minX - l.maxX) } else { notchWidth = 200 }
    }
}

// MARK: - Durum ---------------------------------------------------------------


final class Status: ObservableObject {
    @Published var working = false
    @Published var label = "Ready"
    @Published var tokens = 0
    @Published var startedAt = Date().timeIntervalSince1970
    @Published var contextTokens = 0           // context window kullanımı
    let contextLimit = 1_000_000
    var contextPct: Double { min(1, Double(contextTokens) / Double(contextLimit)) }
    @Published var finishedPulse: Date?
    @Published var doneSticky = false          // bitiş durumu (kart + parlama): SADECE TIKLAYINCA gider
    @Published var doneDur: TimeInterval = 0   // bitiş anındaki süre (donmuş - yeni tur etkilemez)
    @Published var doneTok = 0                 // bitiş anındaki token (donmuş)
    var onComplete: ((TimeInterval, Int) -> Void)?   // HER tamamlanmada doğrudan çağrılır (publisher zamanlamasına güvenme)
    @Published var fiveHourReset: Date?        // 5-saatlik pencerenin sıfırlanma anı (tüm oturumlardan hesaplanır)
    private var timer: Timer?; private var lastScan = Date.distantPast; private var lastWindowScan = Date.distantPast
    private var cPath: String?; private var fileOffset: UInt64 = 0; private var cumTotal = 0; private var lastCtx = 0
    private var scanning = false; private var lastFind = Date.distantPast
    @Published var tokenBaseline = 0
    @Published var endedAt: TimeInterval = 0
    var turnTokens: Int { max(0, tokens - tokenBaseline) }   // bu turun harcadığı (canlı)
    var duration: TimeInterval { (working || endedAt <= startedAt) ? Date().timeIntervalSince1970 - startedAt : endedAt - startedAt }  // idle'da DONAR
    init() {
        // ilk değerleri SENKRON oku - app yeniden başlayınca süre/baseline sıçramasın
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/notch-status.json")
        if let d = FileManager.default.contents(atPath: p), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            working = (o["state"] as? String) == "working"
            startedAt = (o["startedAt"] as? Double) ?? startedAt
            tokenBaseline = (o["tokenBaseline"] as? Int) ?? Int((o["tokenBaseline"] as? Double) ?? 0)
            endedAt = (o["endedAt"] as? Double) ?? 0
        }
        load(); timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick() {
        load()
        if Date().timeIntervalSince(lastScan) > 1.5 && !scanning {
            lastScan = Date(); scanning = true
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.scan(); DispatchQueue.main.async { self?.scanning = false } }
        }
        if Date().timeIntervalSince(lastWindowScan) > 120 { lastWindowScan = Date(); DispatchQueue.global(qos: .background).async { [weak self] in self?.scanWindow() } }
    }
    // 5-saatlik pencere: tüm transcript'lerden zaman damgalarını al, sabit 5s bloklar halinde yürü, son bloğun reset'i
    func scanWindow() {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects"); let fm = FileManager.default
        guard let en = fm.enumerator(atPath: base) else { return }
        let cutoff = Date().addingTimeInterval(-8*3600)   // sadece son 8 saatte aktif dosyalar (5s blok için yeter)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
        var stamps: [Date] = []
        let key = "\"timestamp\":\""
        for case let rel as String in en where rel.hasSuffix(".jsonl") && !rel.contains("subagents") {
            let full = (base as NSString).appendingPathComponent(rel)
            guard let a = try? fm.attributesOfItem(atPath: full), let m = a[.modificationDate] as? Date, m > cutoff,
                  let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: full)) else { continue }
            var pending = Data()
            while let part = try? fh.read(upToCount: 2_000_000), !part.isEmpty {   // parça parça, satır hizalı (düşük RAM)
                pending.append(part)
                guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
                let consume = pending.subdata(in: pending.startIndex..<(lastNL + 1))
                pending = pending.count > lastNL + 1 ? pending.subdata(in: (lastNL + 1)..<pending.endIndex) : Data()
                guard let txt = String(data: consume, encoding: .utf8) else { continue }
                var idx = txt.startIndex
                while let r = txt.range(of: key, range: idx..<txt.endIndex) {
                    guard let e = txt.range(of: "\"", range: r.upperBound..<txt.endIndex) else { break }
                    let ts = String(txt[r.upperBound..<e.lowerBound]); idx = e.upperBound
                    if ts.count >= 20, let d = iso.date(from: ts) ?? iso2.date(from: ts), d > cutoff { stamps.append(d) }
                }
            }
            try? fh.close()
        }
        stamps.sort()
        var blk: Date?
        for t in stamps { if blk == nil || t.timeIntervalSince(blk!) > 5*3600 { blk = t } }
        let reset = blk?.addingTimeInterval(5*3600)
        DispatchQueue.main.async { if self.fiveHourReset != reset { self.fiveHourReset = reset } }
    }
    func load() {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/notch-status.json")
        guard let d = FileManager.default.contents(atPath: p), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let w = (o["state"] as? String) == "working"; let l = (o["label"] as? String) ?? label; let s = (o["startedAt"] as? Double) ?? startedAt
        let tb = (o["tokenBaseline"] as? Int) ?? Int((o["tokenBaseline"] as? Double) ?? 0)
        let ea = (o["endedAt"] as? Double) ?? 0
        let tt = (o["turnTokens"] as? Int) ?? Int((o["turnTokens"] as? Double) ?? 0)
        DispatchQueue.main.async {
            if self.working && !w {   // bitti -> done durumu + değerleri DONDUR
                self.doneDur = ea > s ? ea - s : max(0, Date().timeIntervalSince1970 - s)
                self.doneTok = tt
                self.doneSticky = true
                self.finishedPulse = Date()
                self.onComplete?(self.doneDur, self.doneTok)   // doğrudan tetik (glow + bildirim) - HER bitişte güvenilir
            }
            // yeni tur başlasa bile doneSticky TEMİZLENMEZ - yalnızca tıklama temizler
            // SADECE değişince ata - yoksa @Published her 0.3sn objectWillChange yayar -> gereksiz re-render + sink + resize
            if self.working != w { self.working = w }
            if self.label != l { self.label = l }
            if self.startedAt != s { self.startedAt = s }
            if self.endedAt != ea { self.endedAt = ea }
            if self.tokenBaseline != tb { self.tokenBaseline = tb }
        }
    }
    func scan() {
        let fm = FileManager.default
        // Aktif transcript'i SEYREK bul (her 20sn) - her taramada tüm ağacı gezip yüzlerce dosya stat'lama
        if cPath == nil || Date().timeIntervalSince(lastFind) > 20 {
            lastFind = Date()
            let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
            if let en = fm.enumerator(atPath: base) {
                var newest: (String, Date)?
                for case let rel as String in en where rel.hasSuffix(".jsonl") && !rel.contains("subagents") {
                    let full = (base as NSString).appendingPathComponent(rel)
                    if let a = try? fm.attributesOfItem(atPath: full), let m = a[.modificationDate] as? Date { if newest == nil || m > newest!.1 { newest = (full, m) } }
                }
                if let (p, _) = newest, p != cPath { cPath = p; fileOffset = 0; cumTotal = 0; lastCtx = 0 }   // yeni oturum -> baştan
            }
        }
        guard let path = cPath else { return }
        guard let attrs = try? fm.attributesOfItem(atPath: path), let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < fileOffset { fileOffset = 0; cumTotal = 0; lastCtx = 0 }              // dosya küçüldü (compaction) -> sıfırla
        if size == fileOffset { return }                                                // değişmedi -> çık
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: fileOffset) } catch { return }
        // PARÇA PARÇA oku (1MB) - 36MB'ı tek seferde belleğe almaz, tepe RAM ~birkaç MB
        var absPos = fileOffset, pending = Data()
        while absPos < size {
            let want = Int(min(UInt64(1_000_000), size - absPos))
            guard let part = try? fh.read(upToCount: want), !part.isEmpty else { break }
            absPos += UInt64(part.count); pending.append(part)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }            // tam satır yok -> devam
            let consume = pending.subdata(in: pending.startIndex..<(lastNL + 1))
            let remainder = pending.count - (lastNL + 1)
            fileOffset = absPos - UInt64(remainder)
            pending = remainder > 0 ? pending.subdata(in: (lastNL + 1)..<pending.endIndex) : Data()
            guard let text = String(data: consume, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let ld = line.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                      let m = r["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
                cumTotal += ((u["input_tokens"] as? Int) ?? 0) + ((u["output_tokens"] as? Int) ?? 0) + ((u["cache_creation_input_tokens"] as? Int) ?? 0)
                lastCtx = ((u["input_tokens"] as? Int) ?? 0) + ((u["cache_read_input_tokens"] as? Int) ?? 0) + ((u["cache_creation_input_tokens"] as? Int) ?? 0)  // SON mesaj = anlık bağlam
            }
        }
        let tot = cumTotal, ctx = lastCtx
        DispatchQueue.main.async { if self.tokens != tot { self.tokens = tot }; if self.contextTokens != ctx { self.contextTokens = ctx } }
    }
}
final class UIState: ObservableObject { @Published var expanded = false; @Published var minimal = false }

func fmtTokens(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1e6) : (n >= 1000 ? String(format: "%.1fk", Double(n)/1000) : "\(n)") }
func fmtElapsed(_ s: TimeInterval) -> String {
    let x = max(0, Int(s)); let mn = L("m", "d"), hr = L("h", "sa")   // sn ortak "s"
    return x < 60 ? "\(x)s" : (x < 3600 ? "\(x/60)\(mn) \(x%60)s" : "\(x/3600)\(hr) \((x%3600)/60)\(mn)")
}
let coral = Color(red: 0.86, green: 0.47, blue: 0.34)

// Sunburst spark ikon (menü çubuğu için)
func sparkIcon(_ size: CGFloat, _ color: NSColor, template: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext {
        color.setFill()
        let rays = 11, inner = size * 0.10, outer = size * 0.48, w = size * 0.10
        for i in 0..<rays {
            ctx.saveGState()
            ctx.translateBy(x: size / 2, y: size / 2)
            ctx.rotate(by: CGFloat(i) / CGFloat(rays) * .pi * 2)
            let r = CGRect(x: -w / 2, y: inner, width: w, height: outer - inner)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
    img.unlockFocus()
    img.isTemplate = template
    return img
}

// MARK: - TEMİZ cam (native, sade - overlay yok) ------------------------------

// Gerçek FROSTY cam: arkadaki masaüstünü bulanıklaştırıp gösterir (behindWindow blending)
struct FrostyGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.state = .active }
}

extension View {
    @ViewBuilder func glassy<S: Shape>(_ shape: S) -> some View {
        self.background(FrostyGlass().clipShape(shape))           // arkayı bulanık gösterir = frosty
            .overlay(shape.stroke(.primary.opacity(0.14), lineWidth: 0.6))   // ince cam kenarı
    }
}

// MARK: - Animasyon -----------------------------------------------------------

struct Spark: View {
    var size: CGFloat = 12
    var body: some View {
        TimelineView(.animation) { tl in let t = tl.date.timeIntervalSinceReferenceDate
            Image(systemName: "sparkle").font(.system(size: size, weight: .semibold)).foregroundStyle(coral)
                .scaleEffect(0.82 + 0.18*(0.5+0.5*sin(t*4))).rotationEffect(.degrees(t*35))
        }
    }
}
struct WorkingBars: View {
    var body: some View {
        TimelineView(.animation) { tl in let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) { ForEach(0..<5, id: \.self) { i in Capsule().fill(coral).frame(width: 3, height: 4 + 10*(0.5+0.5*sin(t*6+Double(i)*0.7))) } }
        }
    }
}

// MARK: - Tek birleşik pill (çentiğin SAĞINDA) --------------------------------

struct ComboPill: View {
    @ObservedObject var status: Status
    @ObservedObject var ui: UIState
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let el = status.duration
            HStack(spacing: 7) {
                Spark(); WorkingBars()
                if !ui.minimal {
                    sep
                    Text(locLabel(status.label)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(coral)
                    sep; Text(fmtElapsed(el)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary.opacity(0.9))
                    sep; Text("\(fmtTokens(status.turnTokens)) tok").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary.opacity(0.72))
                }
            }
            .lineLimit(1).fixedSize().padding(.horizontal, 13).frame(height: 25).glassy(Capsule())
        }
    }
    var sep: some View { Text("·").foregroundStyle(.primary.opacity(0.32)).font(.system(size: 11)) }
}

// MARK: - Detay kartı (sağda ayrı, çentikten sarkmaz) -------------------------

struct Card: View {
    @ObservedObject var status: Status
    @ObservedObject var ui: UIState
    var onClose: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let el = status.duration
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Spark(size: 15); Text(status.working ? L("Claude is working", "Claude çalışıyor") : L("Claude is idle", "Claude hazır")).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                    Spacer(); Text(locLabel(status.label)).font(.system(size: 12, weight: .semibold)).foregroundStyle(coral).padding(.horizontal, 9).padding(.vertical, 3).background(coral.opacity(0.16), in: Capsule())
                }
                HStack(spacing: 9) { box(L("Duration", "Süre"), fmtElapsed(el)); box(L("Tokens (this turn)", "Token (bu tur)"), fmtTokens(status.turnTokens)) }
                contextRow
                fiveHourRow
            }
            .padding(16).frame(width: 330, alignment: .leading).glassy(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle()).onTapGesture { onClose() }
        }
    }
    var contextRow: some View {
        let f = status.contextPct
        return VStack(alignment: .leading, spacing: 5) {
            HStack { Text(L("Context window", "Context penceresi")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary); Spacer()
                Text("\(fmtTokens(status.contextTokens)) / 1M  ·  %\(Int(f*100))").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary) }
            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(.primary.opacity(0.12)); Capsule().fill(f > 0.9 ? Color.red : coral).frame(width: max(6, g.size.width*f)) } }.frame(height: 6)
        }.padding(.vertical, 8).padding(.horizontal, 12).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    var fiveHourRow: some View {
        let now = Date(); let reset = status.fiveHourReset
        let frac = reset.map { r -> Double in min(1, max(0, now.timeIntervalSince(r.addingTimeInterval(-5*3600)) / (5*3600))) } ?? 0
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        return VStack(alignment: .leading, spacing: 5) {
            HStack { Text(L("5-hour window", "5-saat penceresi")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary); Spacer()
                Text(reset != nil ? "%\(Int(frac*100))  ·  \(L("Resets", "Sıfırlanma")) \(df.string(from: reset!))" : L("calculating…", "hesaplanıyor…")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary) }
            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(.primary.opacity(0.12)); Capsule().fill(coral.opacity(0.85)).frame(width: max(6, g.size.width*frac)) } }.frame(height: 6)
        }.padding(.vertical, 8).padding(.horizontal, 12).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    func box(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(k).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.primary.opacity(0.55)); Text(v).font(.system(size: 18, weight: .bold)).foregroundStyle(.primary) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 12).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct DonePill: View {
    @ObservedObject var status: Status
    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(coral).font(.system(size: 24, weight: .bold))
                Text(L("Done", "Tamamlandı")).font(.system(size: 19, weight: .bold)).foregroundStyle(.primary)
            }
            HStack(spacing: 28) {
                VStack(spacing: 2) { Text(L("Duration", "Süre")).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary.opacity(0.55)); Text(fmtElapsed(status.doneDur)).font(.system(size: 18, weight: .bold)).foregroundStyle(.primary) }
                VStack(spacing: 2) { Text(L("Tokens", "Token")).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary.opacity(0.55)); Text("\(fmtTokens(status.doneTok)) \(L("spent", "harcandı"))").font(.system(size: 18, weight: .bold)).foregroundStyle(.primary) }
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 17).glassy(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// İnce "çalışıyor" çizgisi - çentiğe yapışık, içeriği KAPATMAZ
struct WorkingLine: View {
    let width: CGFloat
    @State private var on = false
    var body: some View {
        // TimelineView YERİNE repeatForever implicit animation -> Core Animation (GPU) sürdürür, app CPU ~0
        Capsule()
            .fill(LinearGradient(colors: [coral.opacity(0.22), coral, coral.opacity(0.22)], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 5)
            .overlay(
                Capsule().fill(Color.primary.opacity(0.55)).frame(width: 16, height: 5)
                    .offset(x: on ? (width - 16) / 2 : -(width - 16) / 2)
            )
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// İş bitince ekranın dört kenarında TURUNCU parlama (Siri / Apple Intelligence tarzı)
struct ScreenGlow: View {
    @State private var pulse = false
    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 56, style: .continuous) }
    var body: some View {
        // STATİK gradient + shadow (bir kez render) -> akıcı, güvenilir (drawingGroup/blur yok, TimelineView yok)
        let grad = AngularGradient(gradient: Gradient(colors: [
            Color(red: 1.0, green: 0.55, blue: 0.20), Color(red: 0.92, green: 0.40, blue: 0.15),
            coral, Color(red: 1.0, green: 0.72, blue: 0.36), Color(red: 1.0, green: 0.55, blue: 0.20)]),
            center: .center, angle: .degrees(40))
        shape.strokeBorder(grad, lineWidth: 10)
            .shadow(color: Color(red: 1, green: 0.5, blue: 0.18).opacity(0.9), radius: 16)
            .shadow(color: Color(red: 1, green: 0.5, blue: 0.18).opacity(0.55), radius: 34)
            .shadow(color: Color(red: 1, green: 0.5, blue: 0.18).opacity(0.3), radius: 55)
            .ignoresSafeArea()
            .compositingGroup()            // gölgeli görünümü tek katmana düzleştir -> opacity nabzı ucuz composite
            .opacity(pulse ? 1.0 : 0.72)   // nazik nabız - GPU'da (Core Animation), kare başına gölge hesaplama YOK
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Kök: SADECE sağ taraf (sol = menüler, dokunulmaz) --------------------

struct NotchRootView: View {
    let metrics: NotchMetrics
    @ObservedObject var status: Status
    @ObservedObject var ui: UIState
    var showDone: Bool { status.doneSticky }   // yeni tur başlasa bile durur, sadece tıklayınca gider
    func toggle() { withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { ui.expanded.toggle() } }

    var body: some View {
        // ÇENTİĞİN ALTINDA, ORTALI - menü çubuğuyla çakışmaz, içeriği kapatmaz
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)   // çentiği boş geç (kamera)
            if ui.expanded {
                Card(status: status, ui: ui, onClose: { toggle() }).padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
            } else if showDone {
                DonePill(status: status).padding(.top, 6).transition(.move(edge: .top).combined(with: .opacity))
            } else if status.working {
                // sadece ince çizgi - içeriği kapatmaz; tıkla -> detay
                WorkingLine(width: metrics.notchWidth * 0.78).padding(.top, 1)   // kenarlardan biraz daha geniş (az)
                    .onTapGesture { toggle() }.transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: ui.expanded)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: showDone)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: status.working)
    }
}

// Çentik altı minik tıklama yakalayıcı (sadece bu şerit tıklamayı alır)
class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

class ClickHost<Content: View>: NSHostingView<Content> {
    var onRightClick: (() -> Void)?
    var interactiveRects: () -> [NSRect] = { [] }
    override func hitTest(_ point: NSPoint) -> NSView? { for r in interactiveRects() where r.contains(point) { return super.hitTest(point) }; return nil }
    override func rightMouseDown(with event: NSEvent) { let p = convert(event.locationInWindow, from: nil); for r in interactiveRects() where r.contains(p) { onRightClick?(); return } }
}

// MARK: - Uygulama ------------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!; var clickWindow: NSWindow!; var glowWindow: NSWindow!; var glowVisible = false; let status = Status(); let ui = UIState()
    var bag = Set<AnyCancellable>(); var metrics: NotchMetrics!; var sf = NSRect.zero; var rootHost: ClickHost<NotchRootView>!
    var statusItem: NSStatusItem!
    let side: CGFloat = 380
    var showTimer = (UserDefaults.standard.object(forKey: "showTimer") as? Bool) ?? true   // menü çubuğu süresi açık/kapalı

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { status.doneSticky = false; ui.expanded.toggle() }
    }
    func showMenu() {
        let menu = NSMenu()
        let t = NSMenuItem(title: L("Show timer in menu bar", "Menü çubuğunda süreyi göster"), action: #selector(toggleTimer), keyEquivalent: "")
        t.state = showTimer ? .on : .off; t.target = self; menu.addItem(t)
        // Dil alt menüsü
        let langItem = NSMenuItem(title: L("Language", "Dil"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let en = NSMenuItem(title: "English", action: #selector(setEN), keyEquivalent: ""); en.state = appLang == "en" ? .on : .off; en.target = self
        let tr = NSMenuItem(title: "Türkçe", action: #selector(setTR), keyEquivalent: ""); tr.state = appLang == "tr" ? .on : .off; tr.target = self
        langMenu.addItem(en); langMenu.addItem(tr); langItem.submenu = langMenu; menu.addItem(langItem)
        menu.addItem(.separator())
        let q = NSMenuItem(title: L("Quit NotchStatus", "NotchStatus'tan Çık"), action: #selector(quitApp), keyEquivalent: "q")
        q.target = self; menu.addItem(q)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // menüyü göster
        statusItem.menu = nil                  // sol tık tekrar paneli açsın diye sıfırla
    }
    @objc func setEN() { setLang("en") }
    @objc func setTR() { setLang("tr") }
    func setLang(_ l: String) {
        guard appLang != l else { return }
        appLang = l; UserDefaults.standard.set(l, forKey: "lang")
        status.objectWillChange.send(); ui.objectWillChange.send()   // tüm arayüzü yeni dile yenile
    }
    @objc func toggleTimer() {
        showTimer.toggle(); UserDefaults.standard.set(showTimer, forKey: "showTimer")
        if !showTimer, let b = statusItem.button { b.attributedTitle = NSAttributedString(string: "") }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func flashGlow() {
        guard let gw = glowWindow else { return }
        if glowVisible && gw.isVisible && gw.alphaValue > 0.5 { return }   // gerçekten görünüyorsa çık
        glowVisible = true
        let host = NSHostingView(rootView: ScreenGlow())   // her seferinde TAZE içerik (bozuk/eski reuse etme)
        host.frame = NSRect(origin: .zero, size: gw.frame.size); host.autoresizingMask = [.width, .height]
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        gw.contentView = host
        gw.alphaValue = 0; gw.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.5; c.timingFunction = CAMediaTimingFunction(name: .easeOut); gw.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { if self.glowVisible { gw.alphaValue = 1 } }   // animasyon çalışmazsa güvence
    }
    func dismissGlow() {
        guard let gw = glowWindow, glowVisible else { return }
        glowVisible = false
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.5; c.timingFunction = CAMediaTimingFunction(name: .easeIn); gw.animator().alphaValue = 0 },
            completionHandler: { [weak self] in guard let self, !self.glowVisible else { return }; gw.orderOut(nil); gw.contentView = nil })   // fade sırasında yeni bitiş geldiyse koru
    }
    // python3'ü mutlak yolla çöz (stub /usr/bin/python3 gerçekten çalışıyor mu doğrula)
    func resolvePython3() -> String? {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) {
            let t = Process(); t.executableURL = URL(fileURLWithPath: p); t.arguments = ["--version"]
            t.standardOutput = Pipe(); t.standardError = Pipe()
            if (try? t.run()) != nil { t.waitUntilExit(); if t.terminationStatus == 0 { return p } }
        }
        return nil
    }
    // İlk açılış: hook script'ini ~/.claude'a kopyala + settings.json'a hook'ları GÜVENLİ merge et (mevcut hook'lara dokunmaz, idempotent)
    func installHooksIfNeeded() {
        let fm = FileManager.default
        let claude = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        try? fm.createDirectory(atPath: claude, withIntermediateDirectories: true)
        if let src = Bundle.main.path(forResource: "notch_update", ofType: "py") {   // bundle'dan kopyala (.app olarak çalışınca)
            let dst = (claude as NSString).appendingPathComponent("notch_update.py")
            try? fm.removeItem(atPath: dst); try? fm.copyItem(atPath: src, toPath: dst)
        }
        let sp = (claude as NSString).appendingPathComponent("settings.json")
        var root: [String: Any] = [:]
        if let fileData = fm.contents(atPath: sp), !fileData.isEmpty {
            // dosya VAR: yalnızca geçerli JSON object ise devam et; bozuksa DOKUNMA (kullanıcının ayarlarını ezme!)
            guard let parsed = (try? JSONSerialization.jsonObject(with: fileData)) as? [String: Any] else {
                NSLog("NotchStatus: settings.json çözümlenemedi - güvenlik için dokunulmadı"); return
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        guard let pyBin = resolvePython3() else {   // python3 yoksa hook kurma + bir kez net uyar (sessiz ölüm yerine)
            NSLog("NotchStatus: python3 bulunamadı - hook kurulmadı")
            if !UserDefaults.standard.bool(forKey: "py3Warned") {
                UserDefaults.standard.set(true, forKey: "py3Warned")
                let a = NSAlert(); a.messageText = L("Python 3 required", "Python 3 gerekli")
                a.informativeText = L("NotchStatus's status hook needs Python 3. Run this in Terminal, then relaunch the app:\n\n    xcode-select --install",
                                      "NotchStatus durum hook'u Python 3 gerektirir. Terminal'de şunu çalıştırıp uygulamayı yeniden başlatın:\n\n    xcode-select --install")
                a.runModal()
            }
            return
        }
        let py = "\(pyBin) \"$HOME/.claude/notch_update.py\""   // mutlak yol (hook subprocess PATH'i minimal)
        var changed = false
        func ensure(_ event: String, _ mode: String, _ matcher: String?) {
            var arr = hooks[event] as? [[String: Any]] ?? []
            let has = arr.contains { g in (g["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("notch_update.py") ?? false } ?? false }
            if has { return }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\(py) \(mode)"]]]
            if let matcher { entry["matcher"] = matcher }
            arr.append(entry); hooks[event] = arr; changed = true
        }
        ensure("UserPromptSubmit", "start", nil)
        ensure("PreToolUse", "tool", "*")
        ensure("Stop", "stop", nil)
        guard changed else { return }
        root["hooks"] = hooks
        if let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            let bak = sp + ".notchstatus-bak"; try? fm.removeItem(atPath: bak); try? fm.copyItem(atPath: sp, toPath: bak)   // yazmadan önce yedek
            try? d.write(to: URL(fileURLWithPath: sp))
        }
    }
    // app ön planda olmasa bile banner+ses göster
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([.banner, .sound]) }
    func postDoneNotification(_ dur: TimeInterval, _ tok: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // .app gerekli
        let c = UNMutableNotificationContent()
        c.title = L("✅ Claude finished", "✅ Claude tamamlandı")
        c.body = "\(L("Time", "Süre")): \(fmtElapsed(dur))  ·  \(fmtTokens(tok)) \(L("tokens spent", "token harcandı"))"
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "notchstatus.done.\(UUID().uuidString)", content: c, trigger: nil))
        NSSound(named: "Hero")?.play()   // belirgin ses
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        installHooksIfNeeded()   // ilk açılışta hook'ları otomatik kur (settings.json güvenli merge)
        if Bundle.main.bundleIdentifier != nil {   // bildirim için bundle (.app) şart
            let nc = UNUserNotificationCenter.current(); nc.delegate = self
            nc.requestAuthorization(options: [.alert, .sound]) { _, _ in }   // ilk açılışta bir kez izin sorar
        }
        guard let screen = notchScreen() else { NSLog("NotchStatus: ekran bulunamadı"); return }   // ekran yoksa çökme yok
        metrics = NotchMetrics(screen: screen); sf = screen.frame
        let width: CGFloat = 480   // ortalı, dar pencere
        let win = NSWindow(contentRect: rect(160, width), styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true; win.hasShadow = false   // HİÇBİR şeyi bloklamaz (klasör/menü/URL hepsi tıklanır)
        let host = ClickHost(rootView: NotchRootView(metrics: metrics, status: status, ui: ui))
        host.frame = NSRect(origin: .zero, size: win.frame.size); host.autoresizingMask = [.width, .height]
        host.onRightClick = { [weak self] in self?.ui.minimal.toggle() }
        host.interactiveRects = { [weak host, weak self] in
            guard let host, let self else { return [] }
            let b = host.bounds; let nh = self.metrics.notchHeight
            if self.ui.expanded { return [NSRect(x: b.midX - 190, y: b.minY, width: 380, height: b.height - nh)] }  // kart (ortalı)
            let nw = self.metrics.notchWidth
            return [NSRect(x: b.midX - nw/2, y: b.maxY - nh - 18, width: nw, height: 18)]                            // çentik altı ince tıklama şeridi
        }
        win.contentView = host; win.orderFrontRegardless(); window = win; rootHost = host

        // Çentik altı MİNİK tıklama penceresi - SADECE çizgi kadar (ince+dar), yalnızca çalışırken aktif.
        // Boştayken tamamen kapalı -> URL bar / sekme / hiçbir şey engellenmez.
        let cwW = metrics.notchWidth * 0.78 + 24    // çizgi genişliği + ufak pay
        let cwH: CGFloat = 11                         // sadece çizginin olduğu ince şerit (URL bar'a inmez)
        let cw = NSWindow(contentRect: NSRect(x: sf.midX - cwW/2, y: sf.maxY - metrics.notchHeight - cwH, width: cwW, height: cwH),
                          styleMask: .borderless, backing: .buffered, defer: false)
        cw.isOpaque = false; cw.backgroundColor = .clear; cw.level = .statusBar; cw.ignoresMouseEvents = false; cw.hasShadow = false
        cw.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let catcher = ClickCatcher(); catcher.onClick = { [weak self] in self?.ui.expanded.toggle() }
        cw.contentView = catcher; clickWindow = cw   // başlangıçta GİZLİ; sink çalışınca gösterir

        // Tam-ekran parlama penceresi (bitince Siri tarzı) - tıklamayı geçirir, başlangıçta gizli
        let gw = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        gw.isOpaque = false; gw.backgroundColor = .clear; gw.level = .screenSaver; gw.ignoresMouseEvents = true; gw.hasShadow = false
        gw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        gw.alphaValue = 0; glowWindow = gw   // içerik YOK - flashGlow'da oluşturulur, dismiss'te yok edilir (idle'da animasyon = 0 CPU/RAM) (ilk parlamada takılma yok)

        // Menü çubuğu simgesi (sistem alanında) - tıkla: paneli aç/kapat. İçeriği/menüleri bloklamaz.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = sparkIcon(18, .labelColor, template: true)
            b.action = #selector(statusClicked); b.target = self
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])   // sol=panel, sağ=menü
        }

        // Panel açıkken herhangi bir yere tıklayınca kapansın (✦ simgesi hariç = local, tetiklemez)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.ui.expanded || self.status.doneSticky {   // herhangi bir tık -> panel + bitiş efektleri kapanır
                DispatchQueue.main.async { self.ui.expanded = false; self.status.doneSticky = false }
            }
        }

        Publishers.CombineLatest3(ui.$expanded, status.$finishedPulse, status.$working).sink { [weak self] exp,_,w in
            guard let self else { return }
            self.resize(width)
            // tıklama şeridi: SADECE çalışırken ve panel kapalıyken aktif (yoksa hiçbir şeyi engellemez)
            if w && !exp { self.clickWindow.orderFrontRegardless() } else { self.clickWindow.orderOut(nil) }
            if let b = self.statusItem.button {
                b.image = w ? sparkIcon(18, NSColor(red: 0.86, green: 0.47, blue: 0.34, alpha: 1), template: false)
                            : sparkIcon(18, .labelColor, template: true)
            }
        }.store(in: &bag)

        // Bitiş TRIGGER'ı: doğrudan callback (HER tamamlanmada, publisher zamanlamasına bağlı değil)
        status.onComplete = { [weak self] dur, tok in
            guard let self else { return }
            self.flashGlow()                              // glow zaten açıksa no-op
            self.postDoneNotification(dur, tok)
        }
        // doneSticky yalnızca SÖNDÜRME (tıklayınca false -> glow kapanır)
        status.$doneSticky.removeDuplicates().sink { [weak self] sticky in
            guard let self, !sticky else { return }; self.dismissGlow()
        }.store(in: &bag)

        // Menü çubuğu ikonunun YANINDA ufak süre (gönderdiğinden beri) - sadece çalışırken
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let b = self.statusItem.button else { return }
            if self.status.working {
                let x = max(0, Int(self.status.duration))
                let t = String(format: "%d:%02d", x / 60, x % 60)
                b.attributedTitle = NSAttributedString(string: " " + t, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor])
            } else if b.attributedTitle.length > 0 {
                b.attributedTitle = NSAttributedString(string: "")
            }
        }
        // Ekran değişimi (harici monitör tak/çıkar, clamshell, çözünürlük) -> pencereleri yeni çentiğe göre yeniden konumla
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.repositionForScreenChange()
        }
        NSLog("NotchStatus v1: notchW=\(metrics.notchWidth) notchH=\(metrics.notchHeight)")
    }
    func resize(_ w: CGFloat) {
        // pencere her zaman pill/bildirim için yeterince uzun (130); panel için 300
        let extra: CGFloat = ui.expanded ? 320 : 160
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.3; window.animator().setFrame(rect(extra, w), display: true) }
    }
    func rect(_ extra: CGFloat, _ w: CGFloat) -> NSRect { NSRect(x: sf.midX - w/2, y: sf.maxY - (metrics.notchHeight + extra), width: w, height: metrics.notchHeight + extra) }
    func repositionForScreenChange() {
        guard let screen = notchScreen() else { return }
        metrics = NotchMetrics(screen: screen); sf = screen.frame
        window.setFrame(rect(ui.expanded ? 320 : 160, 480), display: true)
        rootHost.rootView = NotchRootView(metrics: metrics, status: status, ui: ui)   // metrics 'let' value -> rootView'i yenile
        let cwW = metrics.notchWidth * 0.78 + 24, cwH: CGFloat = 11
        clickWindow.setFrame(NSRect(x: sf.midX - cwW/2, y: sf.maxY - metrics.notchHeight - cwH, width: cwW, height: cwH), display: true)
        glowWindow.setFrame(screen.frame, display: true)
        glowWindow.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
