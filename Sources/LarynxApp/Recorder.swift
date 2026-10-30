import AVFoundation
import CoreAudio
import AudioToolbox
import LarynxCore

/// Microphone to 16 kHz mono Float32. Every chunk goes to the inflight CAF on disk
/// and to memory for the live preview and the final transcription.
final class Recorder {
    // A fresh engine per recording: one that outlives a mic change (a USB or wireless mic plugged in or out)
    // keeps running but delivers no audio, and leaves Larynx stuck on listening.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var writer: CafWriter?
    private(set) var level: Float = 0 // 0...1, for the pill's meter
    private(set) var micName = "default"
    // Key down to the first audio buffer. Speech before it is lost (the clipped first word).
    private var startedAt: CFAbsoluteTime = 0
    private var heard = false

    var samples: [Float] { lock.lock(); defer { lock.unlock() }; return buffer }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start(writingTo url: URL) throws {
        lock.lock(); buffer = []; lock.unlock()
        startedAt = CFAbsoluteTimeGetCurrent(); heard = false
        writer = try CafWriter(url: url)
        engine = AVAudioEngine()
        let input = engine.inputNode
        // larynx.toml `mic`: the first preferred microphone that is plugged in, else the macOS default.
        // The real name of the macOS default input, so the log shows AirPods or an iPhone, not "default".
        let preferred = Mics.pick(Config.load().mics)
        let fallback = Mics.defaultInput()
        micName = preferred?.1 ?? fallback.map { "default: \($0.1)" } ?? "default"
        var format = input.outputFormat(forBus: 0)
        // Bind the device by id every time, the macOS default too. The node's format goes stale after
        // a mic change or sleep (29 Oct: it said 44.1 kHz stereo for a 48 kHz mono Mac mic), and
        // start() then fails with '!dev' (canPerformIO) on every press until Larynx restarts.
        if let (id, _) = preferred ?? fallback, let unit = input.audioUnit {
            var dev = id
            if AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr {
                // A tap in the wrong format gets no audio or does not start.
                // Ask the device itself, and set that format on the unit's output.
                let rate = Mics.sampleRate(id), ch = Mics.channels(id)
                if rate > 0, ch > 0, let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(ch)) {
                    var asbd = f.streamDescription.pointee
                    let st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                                  &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
                    if st == noErr { format = f }
                    else { NSLog("larynx: mic format %.0f Hz %d ch refused (%d); using the node's format", rate, ch, st) }
                }
            }
        }
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure("no microphone input") }
        // Two-channel receivers (one channel per transmitter) are reduced to mono first.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
        else { throw SpeechFailure("no microphone format") }
        converter = AVAudioConverter(from: mono, to: target)
        NSLog("larynx: mic = %@ (%.0f Hz, %d ch)", micName, format.sampleRate, format.channelCount)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in self?.take(buf) }
        engine.prepare()
        try engine.start()
        NSLog("larynx: mic open after %.0f ms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    }

    /// Stops the mic and closes the file. Returns everything recorded.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
        level = 0
        return samples
    }

    private func take(_ raw: AVAudioPCMBuffer) {
        if !heard { heard = true; NSLog("larynx: first audio after %.0f ms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000) }
        guard let converter, let input = Recorder.mono(raw) else { return }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        writer?.append(chunk)
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()
        level = min(1, rms * 12)
        lock.lock(); buffer += chunk; lock.unlock()
    }
}

extension Recorder {
    /// Keeps the loudest channel of each buffer. A transmitter on either side of a stereo receiver
    /// is heard at full level; an average would halve it (-6 dB) when the other side is empty.
    static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let n = Int(b.format.channelCount)
        guard let src = b.floatChannelData else { return nil }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength), let dst = out.floatChannelData?[0]
        else { return nil }
        out.frameLength = b.frameLength
        let frames = Int(b.frameLength)
        let inter = b.format.isInterleaved
        func sample(_ c: Int, _ f: Int) -> Float { inter ? src[0][f * n + c] : src[c][f] }
        var best = 0, bestEnergy: Float = -1
        for c in 0..<n {
            var e: Float = 0
            for f in 0..<frames { let s = sample(c, f); e += s * s }
            if e > bestEnergy { best = c; bestEnergy = e }
        }
        for f in 0..<frames { dst[f] = sample(best, f) }
        return out
    }
}

/// Input devices by name, through CoreAudio. Reads names only.
enum Mics {
    static func inputs() -> [(AudioDeviceID, String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let name = name(id) else { return nil }
            return (id, name)
        }
    }

    /// The first preference (part of a name, any case) that matches a plugged-in input.
    static func pick(_ prefs: [String]) -> (AudioDeviceID, String)? {
        let all = inputs()
        for p in prefs {
            if let hit = all.first(where: { $0.1.range(of: p, options: .caseInsensitive) != nil }) { return hit }
        }
        return nil
    }

    /// The macOS default input device, if there is one.
    static func defaultInput() -> (AudioDeviceID, String)? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0,
              let n = name(id) else { return nil }
        return (id, n)
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func channels(_ id: AudioDeviceID) -> Int { inputChannels(id) }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

struct SpeechFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
