Project Title: Glotty
Mission: Create a hybrid Translation Engine and Cyber Pet companion that acts as a system-wide utility.

Core Identity
Name: Glotty (derived from "Polyglot").

Role: A digital sidekick that lives in the background, providing instant translations while building a personal relationship with the user through persistent memory.

The "Core Function" (Global Pick-and-Translate)
Action: The user highlights a word or sentence in any software (Chrome, Word, PDF, etc.) and presses a customizable hotkey (e.g., Fn + T).

UI: A "Glotty Window" pops up instantly showing:

The translation.

The phonetic pronunciation.

A friendly greeting or comment from Glotty.

Mechanism: Needs to handle system-level clipboard/selection grabbing and global keyboard hooks.

Cyber Pet & Memory Features
Persistent Memory: Glotty remembers every word or sentence you've ever asked to translate.

Adaptive Greeting: Glotty greets the user based on history (e.g., "Welcome back! Ready to learn more Spanish today?").

Learning Progress: Since it tracks your "picks," it can help you review words you struggle with.

Technical Requirements for Claude
Repository Name: glotty

Operating System: [Insert your OS here: e.g., Windows/macOS].

Key Tasks:

Implement a Global Hotkey listener.

Create a Pop-up UI that doesn't steal focus unnecessarily.

Connect to a translation API and a text-to-speech (TTS) engine.

Set up a local database (like SQLite) for Glotty’s "Memory."
