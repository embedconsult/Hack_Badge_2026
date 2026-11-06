# Minimal runtime pieces for --prelude=empty: just the Pointer and String
# methods the firmware needs, built directly on compiler primitives.

struct Pointer(T)
  @[Primitive(:pointer_new)]
  def self.new(address : UInt64)
  end

  def self.null : self
    new 0_u64
  end

  @[Primitive(:pointer_get)]
  def value : T
  end

  @[Primitive(:pointer_set)]
  def value=(value : T)
  end

  @[Primitive(:pointer_add)]
  def +(offset : Int64) : self
  end

  @[Primitive(:pointer_address)]
  def address : UInt64
  end

  def null? : Bool
    address == 0_u64
  end

  def [](i : Int32) : T
    (self + i.to_i64!).value
  end

  def []=(i : Int32, v : T)
    (self + i.to_i64!).value = v
  end
end

class String
  # String literals are laid out as {type_id, bytesize, length, chars...}.
  def to_unsafe : UInt8*
    pointerof(@c)
  end

  def bytesize : Int32
    @bytesize
  end
end

lib LibRT
  fun abort : NoReturn
end

# Checked arithmetic (+, -, * without &) calls this on overflow.
fun __crystal_raise_overflow : NoReturn
  LibRT.abort
end
