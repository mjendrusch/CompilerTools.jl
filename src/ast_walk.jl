module AstWalker

# This controls the debug print level.  0 prints nothing.  3 print everything.
DEBUG_LVL=0

@doc """
Control how much debugging output is generated by this module.  
Takes one Int argument where: 0 prints nothing. 
Increasing values print more debugging output up to a maximum of debug level 3.
"""
function set_debug_level(x)
    global DEBUG_LVL = x
end

@doc """
Calls print to print a message if the incoming debug level is greater than or equal to the level specified in set_debug_level().
First argument: the detail level of the debugging information.  Higher numbers for higher detail.
Second+ arguments: the message to print if the debug level is satisfied.
"""
function dprint(level,msgs...)
    if(DEBUG_LVL >= level)
        print("AstWalk ", msgs...)
    end
end

@doc """
Calls println to print a message if the incoming debug level is greater than or equal to the level specified in set_debug_level().
First argument: the detail level of the debugging information.  Higher numbers for higher detail.
Second+ arguments: the message to print if the debug level is satisfied.
"""
function dprintln(level,msgs...)
    if(DEBUG_LVL >= level)
        println("AstWalk ", msgs...)
    end
end

export AstWalk

@doc """
Convert a compressed LambdaStaticData format into the uncompressed AST format.
"""
uncompressed_ast(l::LambdaStaticData) =
  isa(l.ast,Expr) ? l.ast : ccall(:jl_uncompress_ast, Any, (Any,Any), l, l.ast)

@doc """
AstWalk through a lambda expression.
Walk through each input parameters and the body of the lambda.
"""
# TODO - it seems we should walk some parts of meta as well.
function from_lambda(ast::Array{Any,1}, depth, callback, cbdata, top_level_number, read)
  assert(length(ast) == 3)
  param = ast[1]
  meta  = ast[2]
  body  = ast[3]

  dprintln(3,"from_lambda pre-convert param = ", param, " typeof(param) = ", typeof(param))
  for i = 1:length(param)
    dprintln(3,"from_lambda param[i] = ", param[i], " typeof(param[i]) = ", typeof(param[i]))
    param[i] = get_one(from_expr(param[i], depth, callback, cbdata, top_level_number, false, read))
  end
  dprintln(3,"from_lambda post-convert param = ", param, " typeof(param) = ", typeof(param))

  dprintln(3,"from_lambda pre-convert body = ", body, " typeof(body) = ", typeof(body))
  body = get_one(from_expr(body, depth, callback, cbdata, top_level_number, false, read))
  dprintln(3,"from_lambda post-convert body = ", body, " typeof(body) = ", typeof(body))
  if typeof(body) != Expr || body.head != :body
    dprintln(0,"AstWalk from_lambda got a non-body returned from procesing body")
    dprintln(0,body)
    throw(string("big problem"))
  end

  ast[1] = param
  ast[2] = meta
  ast[3] = body
  return ast
end

@doc """
AstWalk through an array of expressions.
We know that the first array of expressions we will find is for the lambda body.
top_level_number starts out 0 and if we find it to be 0 then we know that we're processing the array of expr for the body
and so we keep track of the index into body so that users of AstWalk can associate information with particular statements.
Recursively process each element of the array of expressions.
"""
function from_exprs(ast::Array{Any,1}, depth, callback, cbdata, top_level_number, read)
  len  = length(ast)
  top_level = (top_level_number == 0)

  body = Any[]

  for i = 1:len
    if top_level
        top_level_number = length(body) + 1
        dprintln(2,"Processing top-level ast #",i," depth=",depth)
    else
        dprintln(2,"Processing ast #",i," depth=",depth)
    end

    dprintln(3,"AstWalk from_exprs, ast[", i, "] = ", ast[i])
    new_exprs = from_expr(ast[i], depth, callback, cbdata, i, top_level, read)
    dprintln(3,"AstWalk from_exprs done, ast[", i, "] = ", new_exprs)
    assert(isa(new_exprs,Array))
    append!(body, new_exprs)
  end

  return body
end

@doc """
AstWalk through an assignment expression.
Recursively process the left and right hand sides with AstWalk.
"""
function from_assignment(ast::Array{Any,1}, depth, callback, cbdata, top_level_number, read)
#  assert(length(ast) == 2)
  dprintln(3,"from_assignment, lhs = ", ast[1])
  ast[1] = get_one(from_expr(ast[1], depth, callback, cbdata, top_level_number, false, false))
  dprintln(3,"from_assignment, rhs = ", ast[2])
  ast[2] = get_one(from_expr(ast[2], depth, callback, cbdata, top_level_number, false, read))
  return ast
end

@doc """
AstWalk through a call expression.
Recursively process the name of the function and each of its arguments.
"""
function from_call(ast::Array{Any,1}, depth, callback, cbdata, top_level_number, read)
  assert(length(ast) >= 1)
  fun  = ast[1]
  args = ast[2:end]
  dprintln(2,"from_call fun = ", fun, " typeof fun = ", typeof(fun))
  if length(args) > 0
    dprintln(2,"first arg = ",args[1], " type = ", typeof(args[1]))
  end
  # symbols don't need to be translated
  if typeof(fun) != Symbol
      fun = get_one(from_expr(fun, depth, callback, cbdata, top_level_number, false, read))
  end
  args = from_exprs(args, depth+1, callback, cbdata, top_level_number, read)

  return [fun; args]
end

@doc """
Entry point into the code to perform an AST walk.
You generally pass a lambda expression as the first argument.
The third argument is an object that is opaque to AstWalk but that is passed to every callback.
You can use this object to collect data about the AST as it is walked or to hold information on
how to change the AST as you are walking over it.
The second argument is a callback function.  For each AST node, AstWalk will invoke this callback.
The signature of the callback must be (Any, Any, Int64, Bool, Bool).  The arguments to the callback
are as follows:
    1) The current node of the AST being walked.
    2) The callback data object that you originally passed as the first argument to AstWalk.
    3) Specifies the index of the body's statement that is currently being processed.
    4) True if the current AST node being walked is the root of a top-level statement, false if the AST node is a sub-tree of a top-level statement.
    5) True if the AST node is being read, false if it is being written.
The callback should return an array of items.  It does this because in some cases it makes sense to return multiple things so
all callbacks have to to keep the interface consistent.
"""
function AstWalk(ast::Any, callback, cbdata)
  from_expr(ast, 1, callback, cbdata, 0, false, true)
end

@doc """
Callbacks return an array of AST nodes but in most cases this doesn't make sense to replace an AST node with multiple nodes
so we use this function in those cases to assert that the callback returned an array, that it is of length 1 and then we
return that one entry.
"""
function get_one(ast)
  assert(isa(ast,Array))
  assert(length(ast) == 1)
  ast[1]
end

@doc """
Return one element array with element x.
"""
function asArray(x)
  ret = Any[]
  push!(ret, x)
  return ret
end

@doc """
The main routine that switches on all the various AST node types.
The internal nodes of the AST are of type Expr with various different Expr.head field values such as :lambda, :body, :block, etc.
The leaf nodes of the AST all have different types.
There are some node types we don't currently recurse into.  Maybe this needs to be extended.
"""
function from_expr(ast::Any, depth, callback, cbdata, top_level_number, is_top_level, read)
  if typeof(ast) == LambdaStaticData
      ast = uncompressed_ast(ast)
  end
  dprintln(2,"from_expr depth=",depth," ", " ", ast)

  ret = callback(ast, cbdata, top_level_number, is_top_level, read)
  dprintln(2,"callback ret = ",ret)
  if ret != nothing
      return ret
  end

  asttyp = typeof(ast)
  if asttyp == Expr
    dprint(2,"Expr ")
    head = ast.head
    args = ast.args
    typ  = ast.typ
    dprintln(2,head, " ", args)
    if head == :lambda
        args = from_lambda(args, depth, callback, cbdata, top_level_number, read)
    elseif head == :body
        dprintln(2,"Processing :body Expr in AstWalker.from_expr")
        args = from_exprs(args, depth+1, callback, cbdata, top_level_number, read)
        dprintln(2,"Done processing :body Expr in AstWalker.from_expr")
    elseif head == :block
        args = from_exprs(args, depth+1, callback, cbdata, top_level_number, read)
    elseif head == :(.)
        args = from_exprs(args, depth+1, callback, cbdata, top_level_number, read)
    elseif head == :(=)
        args = from_assignment(args, depth, callback, cbdata, top_level_number, read)
    elseif head == :(::)
        assert(length(args) == 2)
        dprintln(3, ":: args[1] = ", args[1])
        dprintln(3, ":: args[2] = ", args[2])
        args[1] = get_one(from_expr(args[1], depth, callback, cbdata, top_level_number, false, read))
    elseif head == :return
        args = from_exprs(args, depth, callback, cbdata, top_level_number, read)
    elseif head == :call
        args = from_call(args, depth, callback, cbdata, top_level_number, read)
        # TODO: catch domain IR result here
    elseif head == :call1
        args = from_call(args, depth, callback, cbdata, top_level_number, read)
        # TODO?: tuple
    elseif head == :line
        # skip
    elseif head == :copy
        # turn array copy back to plain Julia call
        head = :call
        args = vcat(:copy, args)
    elseif head == :copyast
        dprintln(2,"copyast type")
        # skip
    elseif head == :gotoifnot
        assert(length(args) == 2)
        args[1] = get_one(from_expr(args[1], depth, callback, cbdata, top_level_number, false, read))
    elseif head == :getindex
        args = from_exprs(args,depth, callback, cbdata, top_level_number, read)
    elseif head == :new
        args = from_exprs(args,depth, callback, cbdata, top_level_number, read)
    elseif head == :arraysize
        assert(length(args) == 2)
        args[1] = get_one(from_expr(args[1], depth, callback, cbdata, top_level_number, false, read))
        args[2] = get_one(from_expr(args[2], depth, callback, cbdata, top_level_number, false, read))
    elseif head == :alloc
        assert(length(args) == 2)
        args[2] = from_exprs(args[2], depth, callback, cbdata, top_level_number, read)
    elseif head == :boundscheck
        # skip
    elseif head == :type_goto
        assert(length(args) == 2)
        args[1] = get_one(from_expr(args[1], depth, callback, cbdata, top_level_number, false, read))
        args[2] = get_one(from_expr(args[2], depth, callback, cbdata, top_level_number, false, read))
    elseif head == :tuple
        for i = 1:length(args)
          args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
        end
    elseif head == :enter
        # skip
    elseif head == :leave
        # skip
    elseif head == :the_exception
        # skip
    elseif head == :&
        # skip
    elseif head == :ccall
        for i = 1:length(args)
          args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
        end
    elseif head == :function
	  dprintln(3,"in function head")
	  args[2] = get_one(from_expr(args[2], depth, callback, cbdata, top_level_number, false, read))
    elseif head == :vcat
	    dprintln(3,"in vcat head")
	    #skip
    elseif head == :ref
	    for i = 1:length(args)
		    args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
	    end
    elseif head == :meta
	    # ignore :meta for now. TODO: we might need to walk its args.
    elseif head == :comprehension
	    # args are either Expr or Symbol
	    for i = 1:length(args)
		    args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
	    end
    elseif head == :typed_comprehension
	    # args are either Expr or Symbol
	    for i = 1:length(args)
		    args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
	    end
    elseif head == :(:)
	    # args are either Expr or Symbol
	    for i = 1:length(args)
		    args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
	    end
    elseif head == :const
	    dump(ast,1000)
	    # ignore :const for now. 
    elseif head == :for
	    for i = 1:length(args)
		    args[i] = get_one(from_expr(args[i], depth, callback, cbdata, top_level_number, false, read))
	    end
    elseif head == :(+=)
        args[1] = get_one(from_expr(args[1], depth, callback, cbdata, top_level_number, false, false))
        args[2] = get_one(from_expr(args[2], depth, callback, cbdata, top_level_number, false, read))
    else
        throw(string("from_expr: unknown Expr head :", head, " ", ast))
    end
    ast.head = head
    ast.args = args
#    ast = Expr(head, args...)
    ast.typ = typ
  elseif asttyp == Symbol
    dprintln(2,"Symbol type")
    #skip
  elseif asttyp == GenSym
    dprintln(2,"GenSym type")
    #skip
  elseif asttyp == SymbolNode # name, typ
    dprintln(2,"SymbolNode type")
    #skip
  elseif asttyp == TopNode    # name
    dprintln(2,"TopNode type")
    #skip
  elseif isdefined(:GetfieldNode) && asttyp == GetfieldNode  # GetfieldNode = value + name
    dprintln(2,"GetfieldNode type ",typeof(ast.value), " ", ast)
  elseif isdefined(:GlobalRef) && asttyp == GlobalRef
    dprintln(2,"GlobalRef type ",typeof(ast.mod), " ", ast)  # GlobalRef = mod + name
  elseif asttyp == QuoteNode
    value = ast.value
    #TODO: fields: value
    dprintln(2,"QuoteNode type ",typeof(value))
  elseif asttyp == LineNumberNode
    #skip
  elseif asttyp == LabelNode
    #skip
  elseif asttyp == GotoNode
    #skip
  elseif asttyp == DataType
    #skip
  elseif asttyp == ()
    #skip
  elseif asttyp == ASCIIString
    #skip
  elseif asttyp == NewvarNode
    #skip
  elseif asttyp == Nothing
    #skip
  elseif asttyp == Function
    #skip
  #elseif asttyp == Int64 || asttyp == Int32 || asttyp == Float64 || asttyp == Float32
  elseif isbits(asttyp)
    #skip
  elseif isa(ast,Tuple)
    new_tt = Expr(:tuple)
    for i = 1:length(ast)
      push!(new_tt.args, get_one(from_expr(ast[i], depth, callback, cbdata, top_level_number, false, read)))
    end
    new_tt.typ = asttyp
    ast = eval(new_tt)
  elseif asttyp == Module
    #skip
  elseif asttyp == NewvarNode
    #skip
  else
    println(ast, " type = ", typeof(ast), " asttyp = ", asttyp)
    throw(string("from_expr: unknown AST (", typeof(ast), ",", ast, ")"))
  end
  dprintln(3,"Before asArray return for ", ast)
  return asArray(ast)
end

end

