# Dev Mail

A native macOS app that catches email from your local development environment.
Dev Mail runs an SMTP server on your Mac while it's open. Point your app's mail
settings at it, and every message it sends shows up in Dev Mail instead of
reaching a real inbox.

- Accepts every message and recipient, and any SMTP login
- Renders HTML email safely: JavaScript is off and remote content is blocked
  until you allow it for that message
- Plain text and raw source views, and attachments with Quick Look and Save As
- Keeps messages on disk across restarts, with configurable limits

Requires macOS 15 or later.

## Install

With Homebrew:

```sh
brew install --cask hostingaccessories/brews/dev-mail
```

Or download the latest `DevMail-<version>.zip` from
[Releases](https://github.com/hostingaccessories/dev-mail.app/releases),
unzip it and move **Dev Mail** to your Applications folder.

## Usage

Open Dev Mail and configure your app to send mail over SMTP to
**127.0.0.1, port 1025**, with no encryption. Dev Mail doesn't support
TLS/STARTTLS. If your app requires a username and password, any values work.

The host and port can be changed in **Dev Mail → Settings**. The server only
listens on your Mac (`127.0.0.1`) unless you choose another address.

### Laravel

```ini
# .env
MAIL_MAILER=smtp
MAIL_HOST=127.0.0.1
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
```

### Rails

```ruby
# config/environments/development.rb
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = { address: "127.0.0.1", port: 1025 }
```

### Django

```python
# settings.py
EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST = "127.0.0.1"
EMAIL_PORT = 1025
EMAIL_USE_TLS = False
```

### Node.js (Nodemailer)

```js
const transporter = nodemailer.createTransport({
  host: "127.0.0.1",
  port: 1025,
  secure: false,
});
```

### Quick test

```sh
python3 - <<'EOF'
import smtplib
from email.message import EmailMessage

msg = EmailMessage()
msg["From"] = "app@example.test"
msg["To"] = "you@example.test"
msg["Subject"] = "Hello from Dev Mail"
msg.set_content("It works.")

with smtplib.SMTP("127.0.0.1", 1025) as smtp:
    smtp.send_message(msg)
EOF
```

## Where messages are stored

Each message is saved, unchanged, as an `.eml` file in
`~/Library/Application Support/Dev Mail/Messages/`. By default Dev Mail keeps
the most recent 1,000 messages. You can change that, or also delete messages
older than a number of days, in Settings.

Captured mail often contains password reset links and tokens, so the folder is
readable only by your user account.

## Development

Requires Xcode 26 or later and [Homebrew](https://brew.sh).

```sh
make setup   # install tools from the Brewfile (XcodeGen, SwiftLint, ...)
make open    # generate the Xcode project and open it
make run     # build and launch the app
make test    # run the app and package tests
make lint    # check formatting and lint rules
make format  # auto-format Swift sources
```

The Xcode project is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and isn't committed. Change
targets and build settings in `project.yml`, then run `make generate`.

Code that isn't UI (the SMTP server, MIME parsing and storage) lives in the
`DevMailCore` Swift package in `Packages/DevMailCore`, and can be tested on its
own with `swift test --package-path Packages/DevMailCore`.

## License

[MIT](LICENSE)
