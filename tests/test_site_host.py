import unittest

from _load import NODE, cli, js_function, run_js

site_host = cli().site_host


class SiteHost(unittest.TestCase):
    def test_accepts_hosts_and_urls(self):
        cases = {
            "example.com": "example.com",
            "https://WWW.Example.com:8080/a?b#c": "example.com",
            "  news.example.com/item?id=1 ": "news.example.com",
            "ftp://files.example.org": "files.example.org",
            "user@mail.example.co.uk": "mail.example.co.uk",
            "xn--bcher-kva.de": "xn--bcher-kva.de",
        }
        for given, want in cases.items():
            with self.subTest(given=given):
                self.assertEqual(site_host(given), want)

    def test_keeps_subdomains_other_than_www(self):
        self.assertEqual(site_host("www2.example.com"), "www2.example.com")
        self.assertEqual(site_host("docs.example.com"), "docs.example.com")

    def test_rejects_what_is_not_a_site(self):
        for given in ["", None, "   ", "www.", "example", "localhost",
                      "192.168.1.1", "javascript:alert(1)", "bücher.de"]:
            with self.subTest(given=given):
                self.assertEqual(site_host(given), "")


@unittest.skipUnless(NODE, "node not installed")
class AgreesWithTheExtension(unittest.TestCase):
    """A site script is saved under the CLI's key and looked up under the
    extension's. If the two disagree, the script installs cleanly and never
    runs -- with nothing anywhere saying why."""

    URLS = [
        "https://example.com/",
        "https://www.example.com/path?q=1#frag",
        "https://WWW.EXAMPLE.COM/",
        "http://news.example.com:8080/item",
        "https://user:pw@mail.example.co.uk/inbox",
        "https://www2.example.com/",
        "https://a.b.c.example.org/deep/path",
    ]

    def test_same_key_for_the_same_page(self):
        js = run_js(js_function("extension/background.js", "siteHostOf"),
                    "siteHostOf", self.URLS)
        for url, from_js in zip(self.URLS, js):
            with self.subTest(url=url):
                self.assertEqual(site_host(url), from_js)


if __name__ == "__main__":
    unittest.main()
