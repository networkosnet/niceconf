import conf/ast, conf/defs, conf/preparse, conf/exceptions
import tables, strutils, sequtils

type ParserState = object
  root: RootState
  nodes: seq[Node]
  pos: int
  consumeEof: bool
  startOffset: int

proc initState(root: RootState, nodes: seq[Node], startOffset: int): ParserState =
  result.root = root
  result.nodes = nodes
  result.pos = 0
  result.consumeEof = true
  result.startOffset = startOffset

proc splitBySemicolon(nodes: seq[Node]): seq[seq[Node]] =
  result = @[]
  result.add(@[])
  for node in nodes:
    if node.typ == ntSemicolon:
      if result[^1].len != 0:
        result.add(@[])
    else:
      result[^1].add node

proc newConfError[T](state: ParserState, typ: typedesc[T], msg: string): ref T =
  let node = state.nodes[max(min(state.pos, state.nodes.len), 1) - 1]
  newConfError(T, data=state.root.data, offset=node.offset, msg=msg, filename=state.root.filename)

proc consumeNode(state: var ParserState, checkType=meaningfulNodeTypes, allowEof=false): tuple[junkBefore: seq[Node], node: Node] =
  result.junkBefore = @[]
  while true:
    if state.pos >= state.nodes.len:
      if allowEof:
        result.node = nil
        break
      else:
        raise state.newConfError(ParseError, "expected $1, found EOF" % [$checkType])
    let node = state.nodes[state.pos]
    state.pos += 1
    if node.typ in {ntWhitespace, ntComment}:
      result.junkBefore.add node
    elif node.typ notin checkType:
      let expected = if allowEof: (if checkType == {}: "EOF" else: "EOF or " & $checkType) else: $checkType
      raise state.newConfError(ParseError, "expected $1, found $2" % [expected, $node.typ])
    else:
      result.node = node
      break

proc peekUntilNode(state: var ParserState): tuple[junkBefore: seq[Node], node: Node] =
  var savedPos = state.pos
  defer: state.pos = savedPos
  return consumeNode(state, allowEof=true)

proc parseArray(state: var ParserState): Value =
  raise state.newConfError(ParseError, "not implemented")

proc parseDict(state: var ParserState): Value =
  raise state.newConfError(ParseError, "not implemented")

proc parseValue(state: var ParserState): Value =
  let (junkBefore, node) = state.consumeNode({ntString, ntBracketed})
  case node.typ
  of ntBracketed:
    var newState = initState(state.root, node.children, node.offset)
    case node.originalValue
    of "(":
      # TODO: handle () by appending them to junkBefore and junkAfter
      raise state.newConfError(ParseError, "expected value, found '('")
    of "{":
      result = newState.parseDict()
    of "[":
      result = newState.parseArray()
    else: assert false

    result.junkBefore = junkBefore & result.junkBefore
  of ntString:
    newLitteredItem(result, junkBefore, @[], node.offset, state.root)
    result.typ = ValueType.vtString
    result.originalValue = node.originalValue
  else: assert false

proc parseSuite(state: var ParserState, suiteDef: SuiteDef): Suite
proc parseCommand(state: var ParserState, suiteDef: SuiteDef): Command

proc parseSuiteOuter(state: var ParserState, suiteDef: SuiteDef): Suite =
  let (junkBefore, node) = state.consumeNode({ntBracketed})
  if node.originalValue != "{":
    raise state.newConfError(ParseError, "expected '{', found '$1'" % node.originalValue)

  var newState = initState(state.root, node.children, node.offset)
  result = newState.parseSuite(suiteDef)
  # include {} in junk
  result.junkBefore = junkBefore & makeSyntheticWhitespace("{") & result.junkBefore
  result.junkBefore = result.junkAfter & makeSyntheticWhitespace("}")

proc parseArgs(state: var ParserState, argsDef: seq[ArgDef]): tuple[args: seq[Arg], junkAfter: seq[Node]] =
  result.args = @[]
  result.junkAfter = @[]

  let consumeEof = state.consumeEof

  for i in 0..argsDef.len-1:
    let isLast = (i == argsDef.len-1)
    if not isLast:
      state.consumeEof = false

    let argDef = argsDef[i]

    if not argDef.required:
      let hasMore = state.peekUntilNode().node != nil
      if not hasMore:
        break

    case argDef.typ
    of adtValue:
      result.args.add state.parseValue().makeArg
    of adtCommand:
      result.args.add state.parseCommand(argDef.suiteDef.unwrap).makeArg
    of adtSuite:
      result.args.add state.parseSuiteOuter(argDef.suiteDef.unwrap).makeArg
    of adtMoreArgs:
      let ret = parseArgs(state, argDef.args.unwrap)
      if state.consumeEof:
        result.junkAfter = result.junkAfter & ret.junkAfter
      else:
        assert ret.junkAfter.len == 0
      result.args = result.args & ret.args

    state.consumeEof = consumeEof

  if consumeEof:
    let (junkBefore, node) = consumeNode(state, allowEof=true)
    if node != nil: # not EOF
      raise state.newConfError(ParseError, "expected end of arguments, found $1 (missed semicolon?)" % [$node.typ])
    result.junkAfter = result.junkAfter & junkBefore

proc parseCommand(state: var ParserState, suiteDef: SuiteDef): Command =
  let nameValue = parseValue(state)
  if nameValue.typ != ValueType.vtString:
    raise state.newConfError(ParseError, "expected command name, found $1" % [$nameValue.typ])

  let name = nameValue.stringValue
  let commands = suiteDef.allCommands.toTable

  if not commands.hasKey(name):
    let allowedCommands = suiteDef.allCommands.mapIt(string, it.name)
    raise state.newConfError(ParseError, "invalid command $1, expected one of $2" % [name, $allowedCommands])

  if nameValue.junkAfter.len != 0:
    raise state.newConfError(ParseError, "unexpected junk after command name")

  let argsDef = commands[name].unwrap
  newLitteredItem(result, before=nameValue.junkBefore, after=[], offset=nameValue.offset, rootState=state.root)
  result.name = name
  let (args, junkAfter) = state.parseArgs(argsDef)
  result.args = args
  result.junkAfter = junkAfter

proc parseSuite(state: var ParserState, suiteDef: SuiteDef): Suite =
  # suite is always enclosed in brackets
  assert state.consumeEof
  assert state.pos == 0

  let commands = state.nodes.splitBySemicolon()
  newLitteredItem(result, @[], @[], offset=state.startOffset, rootState=state.root)
  result.commands = @[]

  var startOffset = state.startOffset

  for i in 0..commands.len-1:
    let nodes = commands[i]
    var subState = initState(state.root, nodes, startOffset)
    let ret = peekUntilNode(subState)
    if ret.node == nil: # empty statement
      if i == commands.len - 1: # at the end of suite
        result.junkAfter = ret.junkBefore
        break
      else:
        raise subState.newConfError(ParseError, "empty statement")

    result.commands.add parseCommand(subState, suiteDef)
    startOffset = ret.node.offset

proc parse*(data: string, filename: string, suiteDef: SuiteDef): Suite =
  let nodes = preparse(data)
  var rootState: RootState
  new(rootState)
  rootState.data = data
  rootState.filename = filename
  var state = initState(rootState, nodes, 0)
  parseSuite(state, suiteDef)
