# Dev Mail

> [!CAUTION]
> Dev Mail is in alpha and not ready for anyone to actually use.

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

## Command line

Dev Mail includes a `dev-mail` command for working with caught mail from a
terminal. It comes inside the app. To put it on your `PATH`:

```sh
ln -s "/Applications/Dev Mail.app/Contents/MacOS/dev-mail" /usr/local/bin/dev-mail
```

```sh
dev-mail mail list                    # newest first; --search, --unread, -n, --json
dev-mail mail show 7779cab7           # an ID, or its first few characters
dev-mail mail show 7779cab7 --raw     # the original .eml; also --html, --headers, --json
echo "It works" | dev-mail mail send --to you@example.test --subject "Hello"
dev-mail mail send --to you@example.test --html email.html --attach invoice.pdf
dev-mail mail send --eml message.eml  # a complete message, sent as is
dev-mail mail delete 7779cab7 9aaf33de
dev-mail mail delete --all
dev-mail server status
dev-mail server start
dev-mail server stop
dev-mail configure                    # show settings
dev-mail configure --port 2525 --max-messages 500
```

Commands talk to the running app and open it in the background if it isn't
running. `server status` and `server stop` never open it. Run
`dev-mail help <command>` for every option.

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
make setup     # install tools from the Brewfile (XcodeGen, SwiftLint, ...)
make open      # generate the Xcode project and open it
make run       # build and launch the app
make test      # run the app and package tests
make snapshots # render UI screenshots into build/snapshots
make lint      # check formatting and lint rules
make format    # auto-format Swift sources
```

The Xcode project is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and isn't committed. Change
targets and build settings in `project.yml`, then run `make generate`.

### UI snapshots

`make snapshots` renders the main window, message list, message detail and
Settings from fixture messages, in light and dark, into PNGs in
`build/snapshots` (cleared on each run, never committed). Windows are drawn
offscreen inside the test process, so it needs no Screen Recording or
Accessibility permission and captures nothing else on screen. It's how agents
check UI changes by eye; don't use screen capture or UI automation instead.

The snapshot tests are skipped by `make test`. Known gaps: Liquid Glass areas
(the sidebar and toolbar items) render blank or in the light appearance in the
full-window snapshots, so the list is also rendered on its own (`list-*.png`).
A window snapshot taller than 720pt means the content's minimum height didn't
fit.

Code that isn't UI (the SMTP server, MIME parsing and storage) lives in the
`DevMailCore` Swift package in `Packages/DevMailCore`, and can be tested on its
own with `swift test --package-path Packages/DevMailCore`.

## License

[MIT](LICENSE)
