import CorralContracts

public struct DefaultGeometryPolicy: GeometryPolicy {
    public let authoritativeGridSize: GridSize?

    public init(authoritativeGridSize: GridSize? = nil) {
        self.authoritativeGridSize = authoritativeGridSize
    }
}
