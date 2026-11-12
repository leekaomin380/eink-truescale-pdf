import Foundation

@main
struct USBRecoveryTests {
    static func main() {
        var policy = USBRecoveryPolicy()
        var checks = 0
        func expect(_ value: Bool, _ reason: String) {
            precondition(value, reason)
            checks += 1
        }
        expect(!policy.observe(identity: nil, ready: false, now: 0), "unplugged stays idle")
        expect(!policy.observe(identity: 1, ready: false, now: 1), "allow enumeration to settle")
        expect(policy.observe(identity: 1, ready: false, now: 4), "serial device needs preparation")
        expect(!policy.observe(identity: 1, ready: false, now: 100), "one helper at a time")
        policy.finished(now: 100)
        expect(!policy.observe(identity: 1, ready: false, now: 102), "back off after completion")
        expect(policy.observe(identity: 1, ready: false, now: 103), "write succeeded but still serial: retry")
        policy.finished(now: 104)
        expect(!policy.observe(identity: 1, ready: false, now: 109), "second failure increases delay")
        expect(policy.observe(identity: 1, ready: false, now: 110), "busy port or failed switch is retried")
        policy.finished(now: 111)
        expect(!policy.observe(identity: 1, ready: true, now: 112), "observed readiness stops recovery")
        expect(!policy.observe(identity: 1, ready: false, now: 114), "grace after service loss")
        expect(policy.observe(identity: 1, ready: false, now: 115), "sleep/wake loss recovers same USB identity")
        policy.finished(now: 116)
        expect(!policy.observe(identity: 2, ready: false, now: 117), "new registry entry gets grace even without absent poll")
        expect(policy.observe(identity: 2, ready: false, now: 120), "replug with reused serial pathname is a new device session")
        expect(!policy.observe(identity: nil, ready: false, now: 121), "unplug while helper runs")
        expect(!policy.observe(identity: 3, ready: false, now: 122), "replacement cannot launch overlapping helper")
        policy.finished(now: 123) // includes helper timeout / process failure
        expect(policy.observe(identity: 3, ready: false, now: 126), "old completion cannot permanently suppress replacement")
        for index in 0..<20 {
            let now = Double(200 + 100 * index)
            policy.finished(now: now)
            expect(policy.observe(identity: 3, ready: false, now: now + 30), "retries remain bounded at 30 seconds")
        }
        print("USB recovery fault scenarios passed (\(checks) assertions)")
    }
}
