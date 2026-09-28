import Foundation

public enum BundledResources {
    public static var defaultCommands: URL? {
        Bundle.module.url(forResource: "default-commands", withExtension: "yaml")
    }
}
