# Bulletin Board (BBS)

A [meshcore-gui](https://github.com/pe1hvh/meshcore-gui) node can run a bulletin board: messages sorted into categories (for example URGENT, STATUS, ADDRESSES) that anyone on its whitelist can read and post by DM. MeshCore Open keeps a local copy of such a board, so reading old messages costs no airtime.

Requires meshcore-gui 1.26.0 or later (the `!x` sync command); 1.26.4 or later sends compressed replies and drops replies nobody waits for. Not available in the web build.

## Opening a board

1. Open the chat with the BBS node (a normal chat contact).
2. Tap ⋮ → **Bulletin board (BBS)**.

The first time, the screen sends `!h` to fetch the categories; after that, opening the screen only sends `!x` to fetch new messages (`!h` again only when the BBS reports a category the app does not know). A board shows one **All** tab and one tab per category, newest message first. Category names come from the BBS and are not translated.

Pull down on any tab, or tap ↻, to check for new messages. Only messages newer than the newest one in the local copy are fetched; messages deleted by the BBS operator are removed from the copy too.

Messages appear as they arrive, a few per DM. A line under the tabs shows what the sync is doing: **Request sent…**, **Waiting for the BBS…**, **12 of 30 messages received**, or **Poor connection, continuing from 12 messages…** when a reply broke off and the app asks again from the last complete message.

## Posting

Tap **Post**, choose a category (the open tab's category is preselected) and write the message. The counter shows the bytes of the whole `!p` command, which must fit in one DM. Line breaks are sent as spaces, as the BBS shows them.

The app sends `!p` once and does not retry: a second try after a lost confirmation would post the message twice. After **Message posted**, or when no confirmation came, the app syncs so the message appears with the id the BBS gave it. When the BBS refuses the message, its own (English) reply is shown.

## No reply

When the BBS does not answer, the screen shows **No reply from the BBS**: its node did not confirm the request after three tries (out of reach), or confirmed it but sent nothing back. Usually you are not on its whitelist yet: send `!bbs` yourself in the channel chat of the channel the BBS is linked to (ask the BBS operator which one), then retry. The BBS only answers senders on its whitelist, and only knows you after it heard your advert. It may also be out of reach.

## Retention

Each category tab shows how long its messages are kept. The BBS sends this with every sync; the app deletes messages from its copy after the same number of days (default 90). **Kept forever** means the BBS keeps them indefinitely, and so does the app.

## Offline

Without a radio the stored board stays readable; checking for new messages needs a connection (see [offline mode](offline-mode.md)).

## Technical notes

- Replies to `!h` and `!x` are taken out of the chat: they do not appear as messages, raise the unread count or show a notification. Other DMs from the BBS node reach the chat as usual.
- A reply may span several DMs; the BBS sends the next one only after the ACK of the previous one, so messages arrive in order without gaps. The `!x` header announces its number of lines; a reply cut short is resumed from the last complete message.
- One request gets one reply. All tries of a request carry the same timestamp, so the BBS recognises a repeat (meshcore-gui 1.26.1 or later). The app sends a request again only while the BBS node has not confirmed it (ACK); after that it waits as long as the BBS needs to try each reply DM three times (twice along the route, once by flood). meshcore-gui 1.26.4 drops an older sync reply to the same node when a new request comes in, and the app ignores replies to an older request and left-over parts of them (only DMs in the exact sync format; `!r` and `!s` replies typed in the chat still reach it).
- The app asks for a compressed reply (`!x <since_id> <since_del> z`, meshcore-gui 1.26.4): the same reply, deflate-compressed and base64-encoded, in about half the DMs. A BBS that does not know the flag answers with its usage line; the app then asks again without it and keeps doing so for that BBS until the app restarts.
- The copy is stored per radio and per BBS node in `bbs_v1.db`, next to the history database.
