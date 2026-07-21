#if !arch(x86_64)
/// A type-erased wrapper for `GPUSplatCloud<Splat>` that hides the splat type.
///
/// Use `typed(as:)` to recover the underlying typed cloud when needed.
struct AnyGPUSplatCloud: @unchecked Sendable {
    private let storage: Any

    init<Splat: SortableSplatProtocol>(_ cloud: GPUSplatCloud<Splat>) {
        self.storage = cloud
    }

    /// Attempt to recover the underlying typed `GPUSplatCloud`.
    /// Returns `nil` if the splat type doesn't match.
    func typed<Splat: SortableSplatProtocol>(as _: Splat.Type) -> GPUSplatCloud<Splat>? {
        storage as? GPUSplatCloud<Splat>
    }
}
#endif
