/// An `author` or `committer` line: a name, an address in angle brackets,
/// seconds since the epoch, and a timezone offset (`objects.identity-line`).
class Identity {
  final String name;
  final String email;

  /// Seconds since the epoch, as written.
  final int seconds;

  /// The offset exactly as written — `+0000`, `-0500`. Kept as text because it
  /// describes the observer and re-deriving it would change the object's hash.
  final String timezone;

  const Identity({
    required this.name,
    required this.email,
    required this.seconds,
    required this.timezone,
  });

  factory Identity.parse(String line) {
    final open = line.lastIndexOf(' <');
    final close = line.indexOf('>', open + 1);
    if (open < 0 || close < 0) {
      throw FormatException('identity line has no <address>', line);
    }
    final name = line.substring(0, open);
    final email = line.substring(open + 2, close);
    final rest = line.substring(close + 1).trim();
    if (rest.isEmpty) {
      // git permits an identity with no time in some hand-written objects.
      return Identity(name: name, email: email, seconds: 0, timezone: '+0000');
    }
    final parts = rest.split(' ');
    final seconds = int.tryParse(parts[0]);
    if (seconds == null) {
      throw FormatException('identity line has no timestamp', line);
    }
    return Identity(
      name: name,
      email: email,
      seconds: seconds,
      timezone: parts.length > 1 ? parts[1] : '+0000',
    );
  }

  /// The instant this identity records, in UTC.
  DateTime get utc =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  /// The instant as the writer saw it on their own clock, per [timezone].
  DateTime get local => utc.add(offset);

  Duration get offset {
    final sign = timezone.startsWith('-') ? -1 : 1;
    final digits = timezone.replaceAll(RegExp('[+-]'), '');
    if (digits.length != 4) return Duration.zero;
    return Duration(
      hours: sign * int.parse(digits.substring(0, 2)),
      minutes: sign * int.parse(digits.substring(2)),
    );
  }

  @override
  String toString() => '$name <$email> $seconds $timezone';
}

/// An offset as git writes it: `+0000`, `-0530`.
String formatTimezoneOffset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final total = offset.abs();
  final hours = total.inHours.toString().padLeft(2, '0');
  final minutes = (total.inMinutes % 60).toString().padLeft(2, '0');
  return '$sign$hours$minutes';
}
