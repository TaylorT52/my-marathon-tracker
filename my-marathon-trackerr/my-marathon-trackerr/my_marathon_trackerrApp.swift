//
//  my_marathon_trackerrApp.swift
//  my-marathon-trackerr
//
//  Created by Taylor Tam on 7/23/26.
//

import FirebaseCore
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

@main
struct my_marathon_trackerrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RacePortalView()
                .preferredColorScheme(.light)
        }
    }
}
