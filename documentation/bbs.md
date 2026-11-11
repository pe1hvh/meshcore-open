# Bulletin Board (BBS)

A [meshcore-gui](https://github.com/pe1hvh/meshcore-gui) node can run a bulletin board: messages sorted into categories (for example URGENT, STATUS, ADDRESSES) that anyone on its whitelist can read and post by DM. MeshCore Open keeps a local copy of such a board, so reading old messages costs no airtime.

Requires meshcore-gui 1.26.0 or later (the `!x` sync command). Not available in the web build.

## Opening a board

1. Open the chat with the BBS node (a normal chat contact).
2. Tap ⋮ → **Bulletin board (BBS)**.

The screen sends `!h` to fetch the categories, then `!x` to fetch new messages. A board shows one **All** tab and one tab per category, newest message first. Category names come from the BBS and are not translated.

Pull down on any tab, or tap ↻, to check for new messages. Only messages newer than the newest one in the local copy are fetched; messages deleted by the BBS operator are removed from the copy too.

## No reply

When the BBS does not answer after three tries, the screen shows **No reply from the BBS**. Usually you are not on its whitelist yet: send `!bbs` on the channel the BBS is linked to, then retry. The BBS may also be out of reach.

## Retention

Each category tab shows how long its messages are kept. The BBS sends this with every sync; the app deletes messages from its copy after the same number of days (default 90). **Kept forever** means the BBS keeps them indefinitely, and so does the app.

## Offline

Without a radio the stored board stays readable; checking for new messages needs a connection (see [offline mode](offline-mode.md)).

## Technical notes

- Replies to `!h` and `!x` are taken out of the chat: they do not appear as messages, raise the unread count or show a notification. Other DMs from the BBS node reach the chat as usual.
- A reply may span several DMs. The `!x` header announces its number of lines; a reply cut short is resumed from the last complete message at the next sync.
- The copy is stored per radio and per BBS node in `bbs_v1.db`, next to the history database.
- Posting from the app and the whitelist bootstrap are not available yet.
