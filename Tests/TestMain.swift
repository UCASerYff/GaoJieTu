import AppKit
@main struct TestMain {
    @MainActor static func main() async {
        let root=URL(fileURLWithPath:"/private/tmp/GaoJieTu-tests-"+UUID().uuidString)
        do{_ = try GaoPrivateIO.directory(root,create:true,requirePrivate:true);defer{try? FileManager.default.removeItem(at:root)}
            try runCoreTests(in:root);try GaoActionTests.run(in:root.appendingPathComponent("Action"));try runCaptureTests();try await runOCRTests();try await runRecordingTests();try runRecordingAlgorithmTests();try await runRecordingFinalizationRetentionTests();try await runActionRegressionTests(in:root.appendingPathComponent("ActionRegression",isDirectory:true))
            let interop = ProcessInfo.processInfo.environment["GAO_INTEROP_OUTPUT"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? root.appendingPathComponent("Interop",isDirectory:true)
            try await runInteropFixtureGeneration(directory:interop);print("ALL ISOLATED TESTS PASSED")
        }catch{fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)}
    }
}
