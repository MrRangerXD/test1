# 🚀 StrenoxCloud VPS Management Bot

A powerful **Discord VPS deployment and management bot** built with **Python, LXC/LXD, SQLite, and Discord Components V2**.

Deploy and manage VPS instances directly from Discord.

## ✨ Features

- 🖥️ VPS deployment & management
- ⚡ LXC/LXD based virtualization
- 🌐 Multi-node support
- 🔌 TCP/UDP port forwarding
- 📊 VPS resource monitoring
- 🔄 VPS cloning & migration
- ⏰ VPS expiration & renewal
- 👥 VPS sharing
- 🛡️ Admin management
- 🔐 Secure password regeneration
- 🎨 Discord Components V2 UI
- 💾 SQLite database
- 🧰 VPS command execution
- 📦 Docker/nested-container support

## 📋 Requirements

- Ubuntu/Debian Linux server
- Python 3
- LXC/LXD
- Discord Bot
- Discord Developer Portal application

## 🚀 Installation

### 1. Initialize LXD

Run:

```bash
lxd init
```

Follow the setup prompts.

A basic setup can look like:

```text
Would you like to use LXD clustering? no
Do you want to configure a new storage pool? yes
Name of the new storage pool: default
Would you like to connect to a MAAS server? no
Would you like to create a new local network bridge? yes
```

Choose the options that match your server.

### 2. Configure `.env`

Create the environment file:

```bash
nano .env
```

Add your configuration:

```env
TOKEN=YOUR_DISCORD_BOT_TOKEN
CLIENT_ID=YOUR_DISCORD_CLIENT_ID
```

Get both values from the **Discord Developer Portal**.

Save the file and exit:

```text
CTRL + O
ENTER
CTRL + X
```

### 3. Start the Bot

Run:

```bash
python3 bot.py
```

That's it. 🎉

## 🔐 Security

Never share or commit your `.env` file.

Add this to `.gitignore`:

```gitignore
.env
*.db
*.sqlite
*.sqlite3
bot.log
__pycache__/
```

**Never store VPS passwords permanently.** Passwords should only be generated and delivered temporarily.

## 🛠️ Tech Stack

- **Python**
- **discord.py**
- **LXC/LXD**
- **SQLite**
- **Discord Components V2**

## 📌 Project Structure

```text
.
├── bot.py
├── .env
├── vps.db
├── bot.log
└── README.md
```

The bot intentionally uses a **single Python file** to keep development and customization simple.

## ⚠️ Disclaimer

This bot can create, modify, migrate, and delete VPS containers.

Only use it on infrastructure you own or are authorized to manage.

Always keep backups before performing destructive operations.

---

<p align="center">

**VPS Command Center — Deploy. Manage. Monitor. ⚡**

</p>
