import Foundation

// The XML reading behind the eSCL twins (EsclCapabilities.swift, EsclStatus.swift). The C# code
// queries an XDocument; XMLDocument is macOS only, so here Foundation's event-driven XMLParser builds
// a small element tree that is searched the same way: by local name, so the namespace prefixes
// devices use ("scan:", "pwg:", none) do not matter.

/// One element of an eSCL document: its local name (without a namespace prefix), its child elements
/// in document order, and its value (the text of all its descendants, like C# `XElement.Value`).
final class EsclXmlElement {
    let name: String
    var children: [EsclXmlElement] = []
    var value: String = ""

    init(name: String) {
        self.name = name
    }

    /// The first child element named `localName`.
    func child(_ localName: String) -> EsclXmlElement? {
        for element in children where element.name == localName {
            return element
        }
        return nil
    }

    /// Every descendant element named `localName`, in document order; never the element itself.
    func descendants(_ localName: String) -> [EsclXmlElement] {
        var found: [EsclXmlElement] = []
        collect(localName, into: &found)
        return found
    }

    /// The value without surrounding white space; nil when that leaves nothing.
    var text: String? {
        let trimmed: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func collect(_ localName: String, into found: inout [EsclXmlElement]) {
        for element in children {
            if element.name == localName {
                found.append(element)
            }
            element.collect(localName, into: &found)
        }
    }
}

/// Parses eSCL documents into `EsclXmlElement` trees.
enum EsclXml {
    /// The root element of the document in `data`; nil when it is not well-formed XML, with what is
    /// wrong in `error`. External entities are never resolved.
    static func parse(_ data: Data, error: inout String) -> EsclXmlElement? {
        let builder: EsclXmlTreeBuilder = EsclXmlTreeBuilder()
        let parser: XMLParser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let parsed: Bool = parser.parse()
        guard parsed, !builder.failed, let root = builder.root else {
            if let problem = parser.parserError {
                error = problem.localizedDescription
            } else {
                error = "The document has no root element."
            }
            return nil
        }
        return root
    }

    /// "scan:Platen" → "Platen"; a name without a prefix stays as it is.
    static func localName(_ qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }
}

/// Builds the element tree while XMLParser reads the document.
private final class EsclXmlTreeBuilder: NSObject, XMLParserDelegate {
    var root: EsclXmlElement?
    var failed = false
    private var openElements: [EsclXmlElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element: EsclXmlElement = EsclXmlElement(name: EsclXml.localName(elementName))
        if let parent = openElements.last {
            parent.children.append(element)
        } else if root == nil {
            root = element
        } else {
            failed = true
        }
        openElements.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !openElements.isEmpty {
            openElements.removeLast()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }

    /// Text belongs to the value of every element it is inside.
    private func append(_ text: String) {
        for element in openElements {
            element.value += text
        }
    }
}
