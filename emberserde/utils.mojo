# The framework's minimum bound for a value it must move into place and then let
# fall out of scope: movable so it can be stored, implicitly deletable so a `var`
# of the (otherwise erased) type can be dropped without an explicit destructor.
comptime Base = Movable & Deinitable


def unimplemented[name: StaticString]():
    comptime assert False, String("not implemented: ") + String(name)
