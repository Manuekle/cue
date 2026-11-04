import CoreAudio
import CoreMediaIO
import Foundation

/// Detecta cuando cualquier app (Zoom, FaceTime, QuickTime, OBS, Photo Booth, Meet…)
/// enciende la cámara o el micrófono. No necesita permisos: solo consulta el estado
/// de los dispositivos, igual que el punto verde/naranja del sistema.
final class RecordingMonitor: ObservableObject {
    @Published private(set) var cameraInUse = false
    @Published private(set) var microphoneInUse = false

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let camera = Self.isAnyCameraRunning()
        let microphone = Self.isMicrophoneRunning()
        if camera != cameraInUse { cameraInUse = camera }
        if microphone != microphoneInUse { microphoneInUse = microphone }
    }

    // MARK: Cámara (CoreMediaIO)

    static func isAnyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, dataSize, &used, &devices) == noErr else {
            return false
        }
        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var runningUsed: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &runningAddress, 0, nil,
                                                   UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running)
            if status == noErr && running != 0 { return true }
        }
        return false
    }

    // MARK: Micrófono (CoreAudio)

    static func isMicrophoneRunning() -> Bool {
        if #available(macOS 14.4, *) {
            return anyOtherProcessRecordingAudio()
        }
        return defaultInputDeviceRunning()
    }

    @available(macOS 14.4, *)
    private static func anyOtherProcessRecordingAudio() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID {
                continue
            }
            var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(process, &inputAddress, 0, nil, &runningSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private static func defaultInputDeviceRunning() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
