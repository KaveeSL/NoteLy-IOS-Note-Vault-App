NoteLy is a notes app. It also includes an optional Private Vault, disclosed in onboarding and in Settings → Private Vault. There is no hidden button. The vault opens only from Search, and only after the reviewer creates a phrase.

How to open it:

1. Install NoteLy and launch it. The device must have a passcode. Face ID can be enrolled; if it is not, the passcode is the fallback. On the Simulator, use Features → Face ID → Enrolled, and set a passcode.
2. On the third onboarding page, set the secret phrase to: review-vault
   Enter it again to confirm, then tap Enable Private Vault.
   Approve the system prompt. The prompt text is "Unlock your notes".
   You can skip this page and do the same steps later in Settings → Private Vault.
3. Create a normal note. Confirm search, pin, and delete work on that note. A phrase that is not the one from step 2 is an ordinary search and stays on the notes list.
4. Tap Search, type review-vault, and press Return.
5. Approve Face ID or the device passcode.
6. The private note list opens. Create a private note. You can attach a photo; it is encrypted on the device.
7. Tap Lock, or send the app to the background. The private list closes. The app switcher should show the NoteLy cover rather than the private note.
8. Search again for a wrong phrase such as not-the-phrase and press Return. The app stays on the normal notes list and does not show an error about a vault.

review-vault is not built into the app. It only works if you choose it during setup. Phrases are trimmed and not case-sensitive, so Review-Vault also matches. If the phrase is forgotten, those notes cannot be recovered. That is explained on the setup screen.

Private notes stay on the device. They are AES-GCM ciphertext. The key is in the keychain, This Device Only, and is not in backups. The app does not collect data and has no account. Face ID usage: "Used to securely unlock your private notes."

Privacy policy URL: host the PRIVACY.md file in this project and enter that URL here before submission. Nutrition label: Data Not Collected.
