# Fixture: embrace-the-chaos

A real QQ Mail message (multipart/mixed: alternative[plain, html with 2 tables],
an inline cid image, a businesscard link, a `.ics` invite) used by
`test_ingest.py` and `test_reply_integration.py`.

**Anonymized.** Real names, emails, phone, school, the avatar image bytes, and
the QQ auth/session tokens (avatar token, businesscard `code=`, calendar UID)
have been replaced with placeholders (`sender@example.com`,
`recipient@example.com`, `<embrace-the-chaos@example.com>`, a tiny placeholder
PNG, `ANON`). The MIME structure, tables, table values, cid wiring, and the
`wx.mail.qq.com` / `thirdqq.qlogo.cn` hosts are preserved so the tests exercise
the real shape of the message.
