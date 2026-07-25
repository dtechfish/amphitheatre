part of 'amphitheatre_editor.dart';

/// The base class for actions that can be performed by the
/// [AmphitheatreEditor].
@immutable
sealed class AmphitheatreEditorAction {
  /// The unique ID of the crop action. Prefer using the end of the class name
  /// for this to guarantee uniqueness (e.g., [AmphitheatreEditorActionCrop]
  /// would become 'crop').
  String get id;

  const AmphitheatreEditorAction();

  /// Converts the action to a JSON representation. (Typically a
  /// `Map<String, dynamic>`).
  dynamic toJson();
}

/// A crop action. This is when the duration of the video is shortened to a
/// subset within the original video.
final class AmphitheatreEditorActionCrop extends AmphitheatreEditorAction {
  @override
  String get id => 'crop';

  /// The start time in the original video.
  final Duration start;

  /// The end time in the original video.
  final Duration end;

  /// Construct an [AmphitheatreEditorActionCrop].
  const AmphitheatreEditorActionCrop({required this.start, required this.end})
      : assert(end > start, 'end cannot precede start');

  @override
  Map<String, int> toJson() =>
      {'start': start.inMilliseconds, 'end': end.inMilliseconds};

  @override
  bool operator ==(final Object other) =>
      other is AmphitheatreEditorActionCrop &&
      start == other.start &&
      end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// The controller for an [AmphitheatreEditor]. This is used in addition to the
/// [AmphitheatreController] (which is for the video) to control the edit
/// actions that should be applied to the video.
///
/// Continuous gestures (e.g., dragging a crop handle) should apply their
/// intermediate values with `commit: false` and call [commitPending] once the
/// gesture ends: only committed values participate in the undo [history].
final class AmphitheatreEditorController with ChangeNotifier {
  /// The maximum number of history entries retained for [undo].
  static const int maxHistoryLength = 64;

  AmphitheatreEditorModifications _value =
      const AmphitheatreEditorModifications.empty();

  /// The last committed value; the baseline that [commitPending] compares
  /// against.
  AmphitheatreEditorModifications _committed =
      const AmphitheatreEditorModifications.empty();

  /// The initial state of the editor (i.e., the automatically applied default
  /// crop), which does not count as a user modification.
  AmphitheatreEditorModifications _initial =
      const AmphitheatreEditorModifications.empty();

  final ListQueue<AmphitheatreEditorModifications> _history = ListQueue();

  /// The current set of editor modifications.
  AmphitheatreEditorModifications get value => _value;

  /// Check whether the user has modified the video (relative to the editor's
  /// initial state).
  bool get hasModification => _value != _initial;

  /// Whether there is a previous committed state to [undo] to.
  bool get canUndo => _history.isNotEmpty;

  /// Crop the video length to only retain the part between [start] and [end].
  ///
  /// When [commit] is false the change is applied and listeners are notified,
  /// but the change does not enter the undo history until [commitPending] is
  /// called. See [AmphitheatreEditorActionCrop].
  void crop({
    required final Duration start,
    required final Duration end,
    final bool commit = true,
  }) {
    final AmphitheatreEditorModifications next = _value.copyWith(
      crop: AmphitheatreEditorActionCrop(start: start, end: end),
    );

    if (next == _value) return;
    _value = next;
    if (commit) commitPending();
    notifyListeners();
  }

  /// Marks the current value as the editor's initial state. The initial state
  /// does not count as a modification and clears any history.
  ///
  /// This is called by the editor after applying the default crop when the
  /// video loads.
  void markInitial() {
    _initial = _value;
    _committed = _value;
    _history.clear();
    notifyListeners();
  }

  /// Commits the pending value (if it differs from the last committed value),
  /// making it a single entry in the undo history.
  void commitPending() {
    if (_value == _committed) return;

    _history.addLast(_committed);
    while (_history.length > maxHistoryLength) {
      _history.removeFirst();
    }

    _committed = _value;
    notifyListeners();
  }

  /// Reverts to the previously committed state, if there is one.
  void undo() {
    if (_history.isEmpty) return;

    _committed = _history.removeLast();
    _value = _committed;
    notifyListeners();
  }
}

/// The set of modifications to be applied to a video.
@immutable
final class AmphitheatreEditorModifications {
  /// See [AmphitheatreEditorActionCrop].
  final AmphitheatreEditorActionCrop? crop;

  /// Construct a set of [AmphitheatreEditorModifications].
  const AmphitheatreEditorModifications({required this.crop});

  /// Construct a new, empty, set of [AmphitheatreEditorModifications].
  const AmphitheatreEditorModifications.empty() : this(crop: null);

  List<AmphitheatreEditorAction?> get _modifications => [crop];

  /// If [isEmpty] is true, then no modifications have been made.
  bool get isEmpty => _modifications.nonNulls.isEmpty;

  /// If [isNotEmpty] is true, then at least one modification has been made.
  bool get isNotEmpty => _modifications.nonNulls.isNotEmpty;

  /// Check whether every modification that the
  /// [AmphitheatreEditorModifications] supports have been applied.
  bool get hasEveryModification =>
      _modifications.nonNulls.length == _modifications.length;

  /// Copy the set of modifications with a new modification - either replacing
  /// or adding the modification depending on whether it already exists.
  AmphitheatreEditorModifications copyWith({
    final AmphitheatreEditorActionCrop? crop,
  }) =>
      AmphitheatreEditorModifications(crop: crop ?? this.crop);

  /// Copy the set of modifications, only replacing modifications when the new
  /// one is specified and there is not an existing modification of that type.
  AmphitheatreEditorModifications copyWithUnique({
    final AmphitheatreEditorActionCrop? crop,
  }) =>
      AmphitheatreEditorModifications(
        crop: crop != null && this.crop == null ? crop : this.crop,
      );

  /// Build a JSON representation of the modifications.
  Map<String, AmphitheatreEditorAction> toJson() => _modifications.fold(
        <String, AmphitheatreEditorAction>{},
        (final value, final entry) {
          if (entry == null) return value;
          value[entry.id] = entry;
          return value;
        },
      );

  /// Converts the [toJson] representation to a string.
  String toJsonString() => jsonEncode(toJson());

  /// Returns [toJsonString].
  @override
  String toString() => toJsonString();

  @override
  bool operator ==(final Object other) =>
      other is AmphitheatreEditorModifications && crop == other.crop;

  @override
  int get hashCode => crop.hashCode;
}
