import ./types
import ./hclcore as impl

export impl.`[]`, impl.getStr, impl.getBool, impl.getInt, impl.getFloat,
       impl.getStrList, impl.getBlock, impl.getBlocks, impl.findBlock,
       impl.label, impl.hasKey

proc parseHcl*(src: string): HclValue =
  ## Parsuje dokument HCL, rzucając `ZlbError` (nie `hclnim.HclError`) przy
  ## błędzie składni -- zachowuje dotychczasowe zachowanie zlb dla
  ## wywołujących i testów.
  try:
    impl.parseHcl(src)
  except impl.HclError as e:
    raise newException(ZlbError, e.msg)
