"""Swap the WPForms markup for a plain POST form.

WPForms submits over AJAX to /wp-json/... and admin-ajax.php, neither of which
exists on a static host. Left alone the form looks like it works and drops every
enquiry silently. A normal form POST to /contact-send (handled by _worker.js) works
without JavaScript and delivers via Postmark + R2.

Walks the export directory and rewrites every HTML file that carries a WPForms
form. Idempotent: a file already pointing at /contact-send is left untouched.

trupack's contact form (WPForms #298) fields: Name*, Email*, Phone*, Message*.
Mapped to the worker's generic field names: your-name, your-email, your-number,
your-message (+ the "website" honeypot the worker checks first).
"""
import io, os, re, sys

ROOT = sys.argv[1]

# Keep the theme's wpforms-* classes so the existing CSS styles it unchanged.
NEW_FORM = '''<form action="/contact-send" method="post" class="wpforms-form" novalidate="novalidate">
<div class="wpforms-field wpforms-field-name"><label class="wpforms-field-label">Name <span class="wpforms-required-label" aria-hidden="true">*</span></label><input type="text" class="wpforms-field-large wpforms-field-required" name="your-name" placeholder="Full Name" autocomplete="name" required="required"></div>
<div class="wpforms-field wpforms-field-email"><label class="wpforms-field-label">Email <span class="wpforms-required-label" aria-hidden="true">*</span></label><input type="email" class="wpforms-field-large wpforms-field-required" name="your-email" placeholder="Email Address" autocomplete="email" required="required"></div>
<div class="wpforms-field wpforms-field-phone"><label class="wpforms-field-label">Phone <span class="wpforms-required-label" aria-hidden="true">*</span></label><input type="tel" class="wpforms-field-large wpforms-field-required" name="your-number" placeholder="Phone" autocomplete="tel" required="required"></div>
<div class="wpforms-field wpforms-field-textarea"><label class="wpforms-field-label">Message <span class="wpforms-required-label" aria-hidden="true">*</span></label><textarea class="wpforms-field-large wpforms-field-required" name="your-message" rows="6" placeholder="Leave us a message" required="required"></textarea></div>
<div style="position:absolute;left:-9999px" aria-hidden="true"><label>Leave this empty<input type="text" name="website" tabindex="-1" autocomplete="off"></label></div>
<div class="wpforms-submit-container"><button type="submit" class="wpforms-submit">Send Message</button></div>
</form>'''

# The WPForms <form> element, non-greedy to its matching close tag.
FORM_RE = re.compile(r'<form[^>]*wpforms-form[^>]*>.*?</form>', re.S)

changed = 0
scanned = 0
for dirpath, _dirs, files in os.walk(ROOT):
    for name in files:
        if not name.endswith(".html"):
            continue
        p = os.path.join(dirpath, name)
        h = io.open(p, encoding="utf-8", errors="replace").read()
        if "wpforms-form" not in h:
            continue
        scanned += 1
        if 'action="/contact-send"' in h:
            print("  already rewritten: %s" % os.path.relpath(p, ROOT))
            continue
        h2, n = FORM_RE.subn(NEW_FORM, h)
        if n:
            io.open(p, "w", encoding="utf-8", newline="\n").write(h2)
            changed += 1
            print("  rewrote %d WPForms form(s) in %s" % (n, os.path.relpath(p, ROOT)))

print("  form rewrite: %d file(s) with WPForms scanned, %d changed" % (scanned, changed))
