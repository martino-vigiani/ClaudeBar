import Testing

// Tag condivisi per i test del Core. `.networking` marca i test che esercitano il livello di
// rete (sempre mockato, mai live) così è facile filtrarli/escluderli.
extension Tag {
    @Tag static var networking: Self
}
