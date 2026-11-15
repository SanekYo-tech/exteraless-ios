"""Exact NativeServices notification ids and partial native payload projections.

Source contracts: NativeServiceOperations.swift, NativeServicePlayback.swift and
NativeServiceMessageValue.swift. Unknown availability rows are not new codecs.
"""

import math
import ntpath
import posixpath

from ._codec import Snapshot
from ._java_types import ArrayList, File, Object
from ._platform import RuntimeStateError


EVENTS = {
    1: "didReceiveNewMessages", 3: "dialogsNeedReload", 25: "contactsDidLoad",
    46: "mainUserInfoChanged", 137: "didUpdateConnectionState", 142: "fileLoaded",
    143: "fileLoadFailed", 148: "messagePlayingProgressDidChanged",
    150: "messagePlayingPlayStateChanged", 151: "messagePlayingDidStart",
    152: "messagePlayingDidSeek", 306: "onDownloadingFilesChanged",
}
_NO_ARGUMENTS = frozenset((3, 25, 46, 137, 306))


def _integer(value, bits=32):
    return type(value) is int and -(2 ** (bits - 1)) <= value < 2 ** (bits - 1)


def _text(value):
    return isinstance(value, str) and bool(value) and "\0" not in value


def supported_events(rows):
    if not isinstance(rows, list) or len(rows) > 256:
        raise RuntimeStateError("notificationSupported must return a bounded availability table")
    result, seen = [], set()
    for row in rows:
        if not isinstance(row, dict) or not _integer(row.get("id")) or row["id"] <= 0 \
                or not _text(row.get("name")) or len(row["name"].encode("utf-8")) > 256 or row["id"] in seen:
            raise RuntimeStateError("notificationSupported returned an invalid native event")
        seen.add(row["id"])
        expected = EVENTS.get(row["id"])
        if expected is not None:
            if row["name"] != expected:
                raise RuntimeStateError("notificationSupported changed a known native event name")
            result.append(Snapshot(row))
    return result


def _data(value):
    if isinstance(value, dict): return Snapshot((key, _data(item)) for key, item in value.items())
    if isinstance(value, list): return ArrayList(_data(item) for item in value)
    return value


class NativeMessageObject(Snapshot, Object):
    """Supplied native fields, not a TLRPC.Message or a native/JVM pointer."""
    _fqcn = "exteraless.ios.NativeMessageObject"

    def __init__(self, value, account):
        owner = value.get("messageOwner") if isinstance(value, dict) else None
        if not isinstance(owner, dict) or value.get("nativeType") != "MessageObject" or value.get("partial") is not True \
                or not _integer(value.get("currentAccount")) or value["currentAccount"] != account \
                or not _integer(value.get("dialogId"), 64) or not value["dialogId"] \
                or not _integer(value.get("namespace")) or type(value.get("isForwarded")) is not bool \
                or value.get("source") != "Postbox.Message/native-message-v1" \
                or not _integer(owner.get("id")) or not _integer(owner.get("date")) \
                or not isinstance(owner.get("message"), str) or type(owner.get("out")) is not bool \
                or not isinstance(owner.get("peer_id"), dict) or not isinstance(owner.get("entities"), list) \
                or "media" not in owner or "grouped_id" not in owner:
            raise RuntimeStateError("notification requires its complete partial native MessageObject DTO")
        super().__init__((key, _data(item)) for key, item in value.items())

    def getId(self): return self.messageOwner.id
    def getDialogId(self): return self["dialogId"]
    def isOut(self): return self.messageOwner.out
    def isOutOwner(self): return self.messageOwner.out
    def isForwarded(self): return self["isForwarded"]


def notification_arguments(event, account, args):
    if not isinstance(args, list): raise RuntimeStateError("notification arguments must be an array")
    if event in _NO_ARGUMENTS:
        if not args: return []
    elif event == 1:
        if len(args) == 4 and _integer(args[0], 64) and args[0] != 0 and isinstance(args[1], list) \
                and 1 <= len(args[1]) <= 16 and type(args[2]) is bool and type(args[3]) is int and args[3] == 0:
            messages = ArrayList(NativeMessageObject(item, account) for item in args[1])
            if any(message.getDialogId() != args[0] for message in messages):
                raise RuntimeStateError("notification message batch changed its native dialog")
            return [args[0], messages, args[2], args[3]]
    elif event == 142:
        if len(args) == 2 and all(_text(item) for item in args) and (posixpath.isabs(args[1]) or ntpath.isabs(args[1])):
            return [args[0], File(args[1])]
    elif event == 143:
        if len(args) == 2 and _text(args[0]) and _integer(args[1]) and args[1] in (0, 1, 2): return list(args)
    elif event in (148, 152):
        if len(args) == 2 and _integer(args[0]) and type(args[1]) in (int, float) and math.isfinite(args[1]) and 0 <= args[1] <= 1:
            return list(args)
    elif event == 150:
        if len(args) == 1 and _integer(args[0]): return list(args)
    elif event == 151:
        if len(args) == 2:
            return [NativeMessageObject(args[0], account), NativeMessageObject(args[1], account) if args[1] is not None else None]
    raise RuntimeStateError(f"notification {EVENTS.get(event, event)} changed its native argument shape")
