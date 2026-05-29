---
name: mattermost
description: >
  Interacts with the Mattermost API to read, summarize, and send messages, manage
  channels, and retrieve user information. Supports unread checks, mark-as-read,
  channel search, and conversation summaries with user interest preferences.
  WHEN: mattermost messages, check mattermost, unread messages, send message
  to mattermost, mattermost summary, mattermost channels, mark as read.
license: "Apache-2.0"
metadata:
  author: "Canonical"
  version: "1.0.0"
  summary: "Read, summarize, and send Mattermost messages via the REST API"
  tags:
    - mattermost
    - messaging
    - chat
    - canonical
---

# Mattermost

Interact with a Mattermost server via the REST API — read unread messages, summarize
conversations, send messages, manage channels, and mark messages as read.

## Authentication

Credentials are stored in `~/.config/mattermost-skill/config`:

```
MATTERMOST_URL=https://mattermost.example.com
MATTERMOST_TOKEN=your-personal-access-token
```

Read this file at the start of every invocation. If the file does not exist or is
missing either value, stop and instruct the user:

> Create your Mattermost config:
> ```bash
> mkdir -p ~/.config/mattermost-skill
> cat > ~/.config/mattermost-skill/config << 'EOF'
> MATTERMOST_URL=https://mattermost.example.com
> MATTERMOST_TOKEN=your-personal-access-token
> EOF
> chmod 600 ~/.config/mattermost-skill/config
> ```
> Generate a token at: **Profile → Security → Personal Access Tokens**

All API calls use the header: `Authorization: Bearer $MATTERMOST_TOKEN`

### Validate authentication first

```bash
source ~/.config/mattermost-skill/config
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $MATTERMOST_TOKEN" \
  "$MATTERMOST_URL/api/v4/users/me"
```

- HTTP 200 = valid token (response includes `id`, `username`)
- HTTP 401 = invalid/expired token — prompt user to regenerate
- Do not treat the `id` field alone as a success signal; both success and error payloads include an `id` field

## User Preferences

User interest preferences are stored at `~/.config/mattermost-skill/user_preferences.json`.

When summarizing messages:
- Prioritize interested channels first
- Omit or de-emphasize non-interested channels unless explicitly asked
- Preference matching is against `channel.display_name` / `channel.name`

If the preferences file does not exist, create it on first use by asking the user which
channels they care about.

## API Reference

The full API specification is at: https://developers.mattermost.com/api-documentation/

### Core Workflow

1. Validate auth: `GET /api/v4/users/me`
2. Get team unreads: `GET /api/v4/users/{user_id}/teams/unread`
3. Find channels: `GET /api/v4/users/{user_id}/teams/{team_id}/channels`
4. Get posts: `GET /api/v4/channels/{channel_id}/posts?page=0&per_page=15`
5. Post a message: `POST /api/v4/posts` with `{"channel_id":"<id>","message":"..."}`

### Performance Guidelines

- Prefer small, targeted requests; avoid channel-by-channel loops unless needed
- Use parallel requests where possible (ThreadPoolExecutor or concurrent curl)
- Cache channel metadata during a session to avoid re-fetching
- When fetching posts for summaries, fetch 10–15 most recent per channel for full context
- Avoid large response dumps in terminal output; summarize counts and key IDs only
- For "unread today" questions, prefer server-side search:
  `POST /api/v4/teams/{team_id}/posts/search` with `terms: "is:unread after:YYYY-MM-DD"`

### Finding Unread Channels

The correct method to detect unread channels:

```
WRONG:  member.msg_count > 0  (this just means user viewed SOME messages)
CORRECT: channel.total_msg_count > member.msg_count
```

Efficient approach:
1. `GET /api/v4/users/{user_id}/teams/{team_id}/channels/members` → member data per channel
2. `GET /api/v4/users/{user_id}/teams/{team_id}/channels` → channel objects with `total_msg_count`
3. For each channel: `unread = channel.total_msg_count - member.msg_count`

### Mark as Read

**Working endpoint:**
```
POST /api/v4/channels/members/{user_id}/view
Body: {"channel_id": "<id>"}
→ HTTP 200: {status: "OK", last_viewed_at_times: {channel_id: timestamp}}
```

Only call on channels that are actually unread (per the detection method above).

**Bulk mark-as-read pattern:**
```python
members = get(f'/users/{uid}/teams/{tid}/channels/members')
member_map = {m['channel_id']: m for m in members}
channels = get(f'/users/{uid}/teams/{tid}/channels')
for ch in channels:
    unread = ch.get('total_msg_count', 0) - member_map.get(ch['id'], {}).get('msg_count', 0)
    if unread > 0:
        post(f'/channels/members/{uid}/view', {'channel_id': ch['id']})
```

### Bulk User Resolution

`POST /api/v4/users/ids` accepts a JSON array of user IDs and returns user profiles.
Useful for resolving authors when summarizing channel posts.

### Known Endpoint Issues

These endpoints return 404 or errors on some Mattermost server versions (verified on 10.11.6):

| Endpoint | Issue |
|----------|-------|
| `GET /api/v4/users/{uid}/teams/{tid}/channels/unread` | 404 |
| `POST /api/v4/channels/{cid}/members/{uid}/view` | 404 |
| `POST /api/v4/users/{uid}/channels/{cid}/posts/read` | 404 |
| WebSocket `channel_viewed` action | "Unknown WebSocket action" |

## Topic Summary Guidance

When summarizing conversations:
- Include 5–10 most recent messages per channel
- Extract **primary topics**: main discussion theme, decisions, action items, blockers
- Include **key participants** where they drive discussion or decisions
- Note **status**: resolved, in-progress, escalated, waiting on feedback
- Format: **TOPIC NAME** (unread count): 1–2 sentence summary + key messages with context
- Group similar topics together (e.g., multiple channels about the same outage)
- For decision-heavy channels: call out decisions reached, pending, or disagreements

## Self-Maintenance

After each use of this skill, append any newly verified API behavior or operational
lessons to this file. Only record information that was actually validated during the
session. Keep updates concise and place them under the most relevant section.
