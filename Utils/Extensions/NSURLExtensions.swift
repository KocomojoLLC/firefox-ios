/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

private struct ETLDEntry: CustomStringConvertible {
    let entry: String

    var isNormal: Bool { return isWild || !isException }
    var isWild: Bool = false
    var isException: Bool = false

    init(entry: String) {
        self.entry = entry
        self.isWild = entry.hasPrefix("*")
        self.isException = entry.hasPrefix("!")
    }

    private var description: String {
        return "{ Entry: \(entry), isWildcard: \(isWild), isException: \(isException) }"
    }
}

private typealias TLDEntryMap = [String:ETLDEntry]

private func loadEntriesFromDisk() -> TLDEntryMap? {
    if let data = NSString.contentsOfFileWithResourceName("effective_tld_names", ofType: "dat", fromBundle: NSBundle(identifier: "org.mozilla.Shared")!, encoding: NSUTF8StringEncoding, error: nil) {
        let lines = data.componentsSeparatedByString("\n")
        let trimmedLines = lines.filter { !$0.hasPrefix("//") && $0 != "\n" && $0 != "" }

        var entries = TLDEntryMap()
        for line in trimmedLines {
            let entry = ETLDEntry(entry: line)
            let key: String
            if entry.isWild {
                // Trim off the '*.' part of the line
                key = line.substringFromIndex(line.startIndex.advancedBy(2))
            } else if entry.isException {
                // Trim off the '!' part of the line
                key = line.substringFromIndex(line.startIndex.advancedBy(1))
            } else {
                key = line
            }
            entries[key] = entry
        }
        return entries
    }
    return nil
}

private var etldEntries: TLDEntryMap? = {
    return loadEntriesFromDisk()
}()

// MARK: - Local Resource URL Extensions
extension NSURL {

    public func allocatedFileSize() -> Int64 {
        // First try to get the total allocated size and in failing that, get the file allocated size
        return getResourceLongLongForKey(NSURLTotalFileAllocatedSizeKey)
            ?? getResourceLongLongForKey(NSURLFileAllocatedSizeKey)
            ?? 0
    }

    public func getResourceValueForKey(key: String) -> AnyObject? {
        var val: AnyObject?
        do {
            try getResourceValue(&val, forKey: key)
        } catch _ {
            return nil
        }
        return val
    }

    public func getResourceLongLongForKey(key: String) -> Int64? {
        return (getResourceValueForKey(key) as? NSNumber)?.longLongValue
    }

    public func getResourceBoolForKey(key: String) -> Bool? {
        return getResourceValueForKey(key) as? Bool
    }

    public var isRegularFile: Bool {
        return getResourceBoolForKey(NSURLIsRegularFileKey) ?? false
    }

    public func lastComponentIsPrefixedBy(prefix: String) -> Bool {
        return (pathComponents?.last?.hasPrefix(prefix) ?? false)
    }
}

// The list of permanent URI schemes has been taken from http://www.iana.org/assignments/uri-schemes/uri-schemes.xhtml 
private let permanentURISchemes = ["aaa", "aaas", "about", "acap", "acct", "cap", "cid", "coap", "coaps", "crid", "data", "dav", "dict", "dns", "example", "file", "ftp", "geo", "go", "gopher", "h323", "http", "https", "iax", "icap", "im", "imap", "info", "ipp", "ipps", "iris", "iris.beep", "iris.lwz", "iris.xpc", "iris.xpcs", "jabber", "ldap", "mailto", "mid", "msrp", "msrps", "mtqp", "mupdate", "news", "nfs", "ni", "nih", "nntp", "opaquelocktoken", "pkcs11", "pop", "pres", "reload", "rtsp", "rtsps", "rtspu", "service", "session", "shttp", "sieve", "sip", "sips", "sms", "snmp", "soap.beep", "soap.beeps", "stun", "stuns", "tag", "tel", "telnet", "tftp", "thismessage", "tip", "tn3270", "turn", "turns", "tv", "urn", "vemmi", "vnc", "ws", "wss", "xcon", "xcon-userid", "xmlrpc.beep", "xmlrpc.beeps", "xmpp", "z39.50r", "z39.50s"]

extension NSURL {

    public func withQueryParams(params: [NSURLQueryItem]) -> NSURL {
        let components = NSURLComponents(URL: self, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? [])
        for param in params {
            items.append(param)
        }
        components.queryItems = items
        return components.URL!
    }

    public func withQueryParam(name: String, value: String) -> NSURL {
        let components = NSURLComponents(URL: self, resolvingAgainstBaseURL: false)!
        let item = NSURLQueryItem(name: name, value: value)
        components.queryItems = (components.queryItems ?? []) + [item]
        return components.URL!
    }

    public func getQuery() -> [String: String] {
        var results = [String: String]()
        let keyValues = self.query?.componentsSeparatedByString("&")

        if keyValues?.count > 0 {
            for pair in keyValues! {
                let kv = pair.componentsSeparatedByString("=")
                if kv.count > 1 {
                    results[kv[0]] = kv[1]
                }
            }
        }

        return results
    }

    public var hostPort: String? {
        if let host = self.host {
            if let port = self.port?.intValue {
                return "\(host):\(port)"
            }
            return host
        }
        return nil
    }

    public var origin: String? {
        guard isWebPage(includeDataURIs: false), let hostPort = self.hostPort, let scheme = scheme else {
            return nil
        }
        return "\(scheme)://\(hostPort)"
    }

    /**
     * Returns the second level domain (SLD) of a url. It removes any subdomain/TLD
     *
     * E.g., https://m.foo.com/bar/baz?noo=abc#123  => foo
     **/
    public var hostSLD: String {
        guard let publicSuffix = self.publicSuffix, let baseDomain = self.baseDomain else {
            return self.normalizedHost ?? self.URLString
        }
        return baseDomain.stringByReplacingOccurrencesOfString(".\(publicSuffix)", withString: "")
    }

    public var normalizedHostAndPath: String? {
        if let normalizedHost = self.normalizedHost {
            return normalizedHost + (self.path ?? "/")
        }
        return nil
    }

    public var absoluteDisplayString: String? {
        var urlString = self.absoluteString
        // For http URLs, get rid of the trailing slash if the path is empty or '/'
        if (self.scheme == "http" || self.scheme == "https") && (self.path == "/" || self.path == nil) && urlString!.endsWith("/") {
            urlString = urlString!.substringToIndex(urlString!.endIndex.advancedBy(-1))
        }
        // If it's basic http, strip out the string but leave anything else in
        if urlString!.hasPrefix("http://") ?? false {
            return urlString!.substringFromIndex(urlString!.startIndex.advancedBy(7))
        } else {
            return urlString
        }
    }

    public var displayURL: NSURL? {
        if self.isReaderModeURL {
            return self.decodeReaderModeURL?.havingRemovedAuthorisationComponents()
        }

        if self.isErrorPageURL {
            if let decodedURL = self.originalURLFromErrorURL {
                return decodedURL.displayURL
            } else {
                return nil
            }
        }

        if !self.isAboutURL {
            return self.havingRemovedAuthorisationComponents()
        }

        return nil
    }

    /**
    Returns the base domain from a given hostname. The base domain name is defined as the public domain suffix
    with the base private domain attached to the front. For example, for the URL www.bbc.co.uk, the base domain
    would be bbc.co.uk. The base domain includes the public suffix (co.uk) + one level down (bbc).

    :returns: The base domain string for the given host name.
    */
    public var baseDomain: String? {
        guard !isIPv6, let host = host else { return nil }

        // If this is just a hostname and not a FQDN, use the entire hostname.
        if !host.contains(".") {
            return host
        }

        return publicSuffixFromHost(host, withAdditionalParts: 1)
    }

    /**
     * Returns just the domain, but with the same scheme, and a trailing '/'.
     *
     * E.g., https://m.foo.com/bar/baz?noo=abc#123  => https://foo.com/
     *
     * Any failure? Return this URL.
     */
    public var domainURL: NSURL {
        if let normalized = self.normalizedHost {
            // Use NSURLComponents instead of NSURL since the former correctly preserves
            // brackets for IPv6 hosts, whereas the latter escapes them.
            let components = NSURLComponents()
            components.scheme = self.scheme
            components.host = normalized
            components.path = "/"
            return components.URL ?? self
        }
        return self
    }

    public var normalizedHost: String? {
        // Use components.host instead of self.host since the former correctly preserves
        // brackets for IPv6 hosts, whereas the latter strips them.
        guard let components = NSURLComponents(URL: self, resolvingAgainstBaseURL: false), var host = components.host where host != "" else {
            return nil
        }

        if let range = host.rangeOfString("^(www|mobile|m)\\.", options: .RegularExpressionSearch) {
            host.replaceRange(range, with: "")
        }

        return host
    }

    /**
    Returns the public portion of the host name determined by the public suffix list found here: https://publicsuffix.org/list/. 
    For example for the url www.bbc.co.uk, based on the entries in the TLD list, the public suffix would return co.uk.

    :returns: The public suffix for within the given hostname.
    */
    public var publicSuffix: String? {
        if let host = self.host {
            return publicSuffixFromHost(host, withAdditionalParts: 0)
        } else {
            return nil
        }
    }

    public func isWebPage(includeDataURIs includeDataURIs: Bool = true) -> Bool {
        let schemes = includeDataURIs ? ["http", "https", "data"] : ["http", "https"]
        if let scheme = scheme where schemes.contains(scheme) {
            return true
        }

        return false
    }

    public var isLocal: Bool {
        guard isWebPage(includeDataURIs: false) else {
            return false
        }
        // iOS forwards hostless URLs (e.g., http://:6571) to localhost.
        guard let host = host where !host.isEmpty else {
            return true
        }

        return host.lowercaseString == "localhost" || host == "127.0.0.1"
    }

    public var isIPv6: Bool {
        return host?.containsString(":") ?? false
    }
    
    /**
     Returns whether the URL's scheme is one of those listed on the official list of URI schemes.
     This only accepts permanent schemes: historical and provisional schemes are not accepted.
     */
    public var schemeIsValid: Bool {
        guard let scheme = scheme else { return false }
        return permanentURISchemes.contains(scheme)
    }

    public func havingRemovedAuthorisationComponents() -> NSURL {
        guard let urlComponents = NSURLComponents(URL: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        urlComponents.user = nil
        urlComponents.password = nil
        if let url = urlComponents.URL {
            return url
        }
        return self
    }
}

// Extensions to deal with ReaderMode URLs

extension NSURL {
    public var isReaderModeURL: Bool {
        let scheme = self.scheme, host = self.host, path = self.path
        return scheme == "http" && host == "localhost" && path == "/reader-mode/page"
    }

    public var decodeReaderModeURL: NSURL? {
        if self.isReaderModeURL {
            if let components = NSURLComponents(URL: self, resolvingAgainstBaseURL: false), queryItems = components.queryItems where queryItems.count == 1 {
                if let queryItem = queryItems.first, value = queryItem.value {
                    return NSURL(string: value)
                }
            }
        }
        return nil
    }

    public func encodeReaderModeURL(baseReaderModeURL: String) -> NSURL? {
        if let absoluteString = self.absoluteString {
            if let encodedURL = absoluteString.stringByAddingPercentEncodingWithAllowedCharacters(NSCharacterSet.alphanumericCharacterSet()) {
                if let aboutReaderURL = NSURL(string: "\(baseReaderModeURL)?url=\(encodedURL)") {
                    return aboutReaderURL
                }
            }
        }
        return nil
    }
}

// Helpers to deal with ErrorPage URLs

extension NSURL {
    public var isErrorPageURL: Bool {
        if let host = self.host, path = self.path {
            return self.scheme == "http" && host == "localhost" && path == "/errors/error.html"
        }
        return false
    }

    public var originalURLFromErrorURL: NSURL? {
        let components = NSURLComponents(URL: self, resolvingAgainstBaseURL: false)
        if let queryURL = components?.queryItems?.find({ $0.name == "url" })?.value {
            return NSURL(string: queryURL)
        }
        return nil
    }
}

// Helpers to deal with About URLs
extension NSURL {
    public var isAboutHomeURL: Bool {
        if let urlString = self.getQuery()["url"]?.unescape() where isErrorPageURL {
            let url = NSURL(string: urlString) ?? self
            return url.aboutComponent == "home"
        }
        return self.aboutComponent == "home"
    }

    public var isAboutURL: Bool {
        return self.aboutComponent != nil
    }

    /// If the URI is an about: URI, return the path after "about/" in the URI.
    /// For example, return "home" for "http://localhost:1234/about/home/#panel=0".
    public var aboutComponent: String? {
        let aboutPath = "/about/"
        guard let scheme = self.scheme, host = self.host, path = self.path else {
            return nil
        }
        if scheme == "http" && host == "localhost" && path.startsWith(aboutPath) {
            return path.substringFromIndex(aboutPath.endIndex)
        }
        return nil
    }

}

//MARK: Private Helpers
private extension NSURL {
    private func publicSuffixFromHost( host: String, withAdditionalParts additionalPartCount: Int) -> String? {
        if host.isEmpty {
            return nil
        }

        // Check edge case where the host is either a single or double '.'.
        if host.isEmpty || NSString(string: host).lastPathComponent == "." {
            return ""
        }

        /**
        *  The following algorithm breaks apart the domain and checks each sub domain against the effective TLD
        *  entries from the effective_tld_names.dat file. It works like this:
        *
        *  Example Domain: test.bbc.co.uk
        *  TLD Entry: bbc
        *
        *  1. Start off by checking the current domain (test.bbc.co.uk)
        *  2. Also store the domain after the next dot (bbc.co.uk)
        *  3. If we find an entry that matches the current domain (test.bbc.co.uk), perform the following checks:
        *    i. If the domain is a wildcard AND the previous entry is not nil, then the current domain matches
        *       since it satisfies the wildcard requirement.
        *    ii. If the domain is normal (no wildcard) and we don't have anything after the next dot, then
        *        currentDomain is a valid TLD
        *    iii. If the entry we matched is an exception case, then the base domain is the part after the next dot
        *
        *  On the next run through the loop, we set the new domain to check as the part after the next dot,
        *  update the next dot reference to be the string after the new next dot, and check the TLD entries again.
        *  If we reach the end of the host (nextDot = nil) and we haven't found anything, then we've hit the 
        *  top domain level so we use it by default.
        */

        let tokens = host.componentsSeparatedByString(".")
        let tokenCount = tokens.count
        var suffix: String?
        var previousDomain: String? = nil
        var currentDomain: String = host

        for offset in 0..<tokenCount {
            // Store the offset for use outside of this scope so we can add additional parts if needed
            let nextDot: String? = offset + 1 < tokenCount ? tokens[offset + 1..<tokenCount].joinWithSeparator(".") : nil

            if let entry = etldEntries?[currentDomain] {
                if entry.isWild && (previousDomain != nil) {
                    suffix = previousDomain
                    break
                } else if entry.isNormal || (nextDot == nil) {
                    suffix = currentDomain
                    break
                } else if entry.isException {
                    suffix = nextDot
                    break
                }
            }

            previousDomain = currentDomain
            if let nextDot = nextDot {
                currentDomain = nextDot
            } else {
                break
            }
        }

        var baseDomain: String?
        if additionalPartCount > 0 {
            if let suffix = suffix {
                // Take out the public suffixed and add in the additional parts we want.
                let literalFromEnd: NSStringCompareOptions = [NSStringCompareOptions.LiteralSearch,        // Match the string exactly.
                                     NSStringCompareOptions.BackwardsSearch,      // Search from the end.
                                     NSStringCompareOptions.AnchoredSearch]         // Stick to the end.
                let suffixlessHost = host.stringByReplacingOccurrencesOfString(suffix, withString: "", options: literalFromEnd, range: nil)
                let suffixlessTokens = suffixlessHost.componentsSeparatedByString(".").filter { $0 != "" }
                let maxAdditionalCount = max(0, suffixlessTokens.count - additionalPartCount)
                let additionalParts = suffixlessTokens[maxAdditionalCount..<suffixlessTokens.count]
                let partsString = additionalParts.joinWithSeparator(".")
                baseDomain = [partsString, suffix].joinWithSeparator(".")
            } else {
                return nil
            }
        } else {
            baseDomain = suffix
        }

        return baseDomain
    }
}
