module Parser #JSON

using Compat

#Define ordered dictionary from DataStructures if present
_HAVE_DATASTRUCTURES = try
    using DataStructures
    import DataStructures.OrderedDict
    true
catch
    false
end

const TYPES = Any # Union(Dict, Array, AbstractString, Number, Bool, Nothing) # Types it may encounter
const KEY_TYPES = Union(AbstractString) # Types it may encounter as object keys

export parse

type ParserState{T<:AbstractString}
    str::T
    s::Int
    e::Int
end

ParserState(str::AbstractString,s::Int,e::Int) = ParserState(str, s, e)


charat{T<:AbstractString}(ps::ParserState{T}) = ps.str[ps.s]
incr(ps::ParserState) = (ps.s += 1)
hasmore(ps::ParserState) = (ps.s < ps.e)


# UTILITIES

# Eat up spaces starting at s.
function chomp_space{T<:AbstractString}(ps::ParserState{T})
    c = charat(ps)
    while isspace(c) && hasmore(ps)
        incr(ps)
        c = charat(ps)
    end
end

# Run past the separator in a name : value pair
function skip_separator{T<:AbstractString}(ps::ParserState{T})
    while (charat(ps) != ':') && hasmore(ps)
        incr(ps)
    end
    (charat(ps) != ':') && error("Separator not found ", ps)
    incr(ps)
    nothing
end


# Used for line counts
function _count_before{T<:AbstractString}(haystack::T, needle::Char, _end::Int)
    count = 0
    i = 1
    while i < _end
        haystack[i]==needle && (count += 1)
        i += 1
    end
    count
end

# Prints an error message with an indicator to the source
function _error(message::AbstractString, ps::ParserState)
    lines = _count_before(ps.str, '\n', ps.s)
    # Replace all special multi-line/multi-space characters with a space.
    strnl = replace(ps.str, r"[\b\f\n\r\t\s]", " ")
    li = (ps.s > 20) ? ps.s - 9 : 1 # Left index
    ri = min(ps.e, ps.s + 20)       # Right index
    error(message *
      "\nLine: " * string(lines) *
      "\nAround: ..." * strnl[li:ri] * "..." *
      "\n           " * (" " ^ (ps.s - li)) * "^\n"
    )
end

# PARSING

function parse_array{T<:AbstractString}(ps::ParserState{T}, ordered::Bool, quote_char::Char)
    incr(ps) # Skip over the '['
    _array = TYPES[]
    chomp_space(ps)
    charat(ps)==']' && (incr(ps); return _array) # Check for empty array
    while true # Extract values from array
        v = parse_value(ps, ordered, quote_char) # Extract value
        push!(_array, v)
        # Eat up trailing whitespace
        chomp_space(ps)
        c = charat(ps)
        if c == ','
            incr(ps)
            continue
        elseif c == ']'
            incr(ps)
            break
        else
            _error("Unexpected char: " * string(c), ps)
        end
    end
    return _array
end

function parse_object{T<:AbstractString}(ps::ParserState{T}, ordered::Bool, quote_char::Char)
    if ordered
        parse_object(ps, ordered, quote_char, OrderedDict{KEY_TYPES,TYPES}())
    else
        parse_object(ps, ordered, quote_char, Dict{KEY_TYPES,TYPES}())
    end
end

function parse_object{T<:AbstractString}(ps::ParserState{T}, ordered::Bool, quote_char::Char, obj)
    incr(ps) # Skip over opening '{'
    chomp_space(ps)
    charat(ps)=='}' && (incr(ps); return obj) # Check for empty object
    while true
        chomp_space(ps)
        _key = parse_string(ps, quote_char)           # Key
        skip_separator(ps)
        _value = parse_value(ps, ordered, quote_char) # Value
        obj[_key] = _value                             # Building object
        chomp_space(ps)
        c = charat(ps) # Find the next pair or end of object
        if c == ','
            incr(ps)
            continue
        elseif c == '}'
            incr(ps)
            break
        else
            _error("Unexpected char: " * string(c), ps)
        end
    end
    return obj
end

utf16_is_surrogate(c::Uint16) = (c & 0xf800) == 0xd800
utf16_get_supplementary(lead::Uint16, trail::Uint16) = @compat(Char(@compat(UInt32(lead-0xd7f7)<<10) + trail))

# TODO: Try to find ways to improve the performance of this (currently one
#       of the slowest parsing methods).
function parse_string{T<:AbstractString}(ps::ParserState{T}, quote_char::Char)
    str = ps.str
    s = ps.s
    e = ps.e

    str[s] == quote_char || _error("Missing opening string char", ps)
    s = nextind(str, s) # Skip over opening quote_char '"'
    b = IOBuffer()
    found_end = false
    while s <= e
        c = str[s]
        if c == '\\'
            s = nextind(str, s)
            c = str[s]
            if c == 'u' # Unicode escape
                u = unescape_string(str[s - 1:s + 4]) # Get the string
                c = u[1]
                if utf16_is_surrogate(@compat(UInt16(c)))
                    if str[s+5] != '\\' || str[s+6] != 'u'
                        _error("Unmatched UTF16 surrogate", ps)
                    end
                    u2 = unescape_string(str[s + 5:s + 10])
                    c = utf16_get_supplementary(@compat(UInt16(c)),@compat(UInt16(u2[1])))
                    # Skip the additional 6 characters
                    for _ = 1:6
                        s = nextind(str, s)
                    end
                end
                write(b, c)
                # Skip over those next four characters
                for _ = 1:4
                    s = nextind(str, s)
                end
            elseif c == '"'  write(b, '"' )
            elseif c == '\\' write(b, '\\')
            elseif c == '/'  write(b, '/' )
            elseif c == 'b'  write(b, '\b')
            elseif c == 'f'  write(b, '\f')
            elseif c == 'n'  write(b, '\n')
            elseif c == 'r'  write(b, '\r')
            elseif c == 't'  write(b, '\t')
            elseif c == '\'' && quote_char == '\'' write(b, '\'') # not part of standard
            else _error("Unrecognized escaped character: " * string(c), ps)
            end
        elseif c == quote_char
            found_end = true
            s = nextind(str, s)
            break
        else
            write(b, c)
        end
        s = nextind(str, s)
    end
    ps.s = s
    found_end || _error("Unterminated string", ps)
    takebuf_string(b)
end

function parse_simple{T<:AbstractString}(ps::ParserState{T})
    c = charat(ps)
    if c == 't' && ps.str[ps.s + 3] == 'e'     # Looks like "true"
        ps.s += 4
        ret = true
    elseif c == 'f' && ps.str[ps.s + 4] == 'e' # Looks like "false"
        ps.s += 5
        ret = false
    elseif c == 'n' && ps.str[ps.s + 3] == 'l' # Looks like "null"
        ps.s += 4
        ret = nothing
    else
        _error("Unknown simple: " * string(c), ps)
    end
    ret
end

function parse_value{T<:AbstractString}(ps::ParserState{T}, ordered::Bool, quote_char::Char)
    chomp_space(ps)
    (ps.s > ps.e) && return nothing # Nothing left
    leniant = true
    
    ch = charat(ps)
    if ch == quote_char
        ret = parse_string(ps, quote_char)
    elseif ch == '{'
        ret = parse_object(ps, ordered, quote_char)
    elseif (ch >= '0' && ch <= '9') || ch=='-' || ch=='+' || (leniant && ch=='I' || ch=='N')
        ret = parse_number(ps, true)
    elseif ch == '['
        ret = parse_array(ps, ordered, quote_char)
    elseif ch == 'f' || ch == 't' || ch == 'n'
        ret = parse_simple(ps)
    else
        _error("Unknown value", ps)
    end
    return ret
end

if VERSION < v"0.4.0-dev+3874"
    function tryparse(T::Type{Float64},str::AbstractString)
        temp = Array(Float64,1)
        if float64_isvalid(str,temp)
            return Nullable(temp[1])
        else
            return Nullable{Float64}()
        end
    end
end

function parse_number{T<:AbstractString}(ps::ParserState{T}, leniant::Bool)
    str = ps.str
    p = ps.s
    e = ps.e
    is_float = false

    c = str[p]
    if c=='-' || c=='+' # Look for sign
        p += 1
        (p <= e) ? (c = str[p]) : _error("Unrecognized number", ps)  # Something must follow a sign
    end
    
    if leniant && (str[p]=='I' || str[p]=='N') 
        vs = SubString(ps.str, ps.s, p+2)
        @show(vs)
        ps.s = p+3
        return Base.parse(Float64, vs)
    end

    if c == '0' # If number begins with 0, it must be int(0) or a floating point
        p += 1
        if p <= e
            if str[p] == '.'
                is_float = true
                p += 1
            end
        end
    elseif '0' < c <= '9' # Match more digits
        while '0' <= c <= '9'
            p += 1
            (p <= e) ? (c = str[p]) : break
        end
        if (p <= e) && (c == '.')
            is_float = true
            p += 1
        end
    else
        _error("Unrecognized number", ps)
    end

    if p <= e
        c = str[p]

        if is_float # Match digits after decimal
            while '0' <= c <= '9'
                p += 1
                (p <= e) ? (c = str[p]) : break
            end
        end

        if c == 'E' || c == 'e' || c == 'f' || c == 'F'
            is_float = true
            p += 1
            (p > e) && _error("Unrecognized number", ps)
            c = str[p]
            if c == '-' || c == '+' # Exponent sign
                p += 1
                (p > e) && _error("Unrecognized number", ps)
                c = str[p]
            end
            while '0' <= c <= '9' # Exponent digits
                p += 1
                (p <= e) ? (c = str[p]) : break
            end
        end
    end

    vs = SubString(ps.str, ps.s, p-1)
    ps.s = p
    if is_float
        tmp64 = tryparse(Float64,vs)
        isnull(tmp64) ? error("Invalid floating point number", ps) : return get(tmp64)
    else
        return Base.parse(Int, vs)
    end
end

function parse(str::AbstractString; ordered::Bool=false, single_quote::Bool=false)
    pos::Int = 1
    len::Int = endof(str)
    quote_char::Char = single_quote ? '\'' : '\"'
    len < 1 && return 
    ordered && !_HAVE_DATASTRUCTURES && error("DataStructures package required for ordered parsing: try `Pkg.add(\"DataStructures\")`")
    parse_value(ParserState(str, pos, len), ordered, quote_char)
end

# Allow post-fix options in the forms: "so!" or "single_ordered" or "os!", etc. 
function _parse(str::AbstractString, opt::Tuple)
    if opt |> isempty
        parse(str)
    else
        opts = opt[1][end] != '!' ? split(opt[1], "_") : split(opt[1], "")
        opts = [ c[1] for c in opts ]
        parse(str, ordered ='o' in opts, single_quote = 's' in opts)
    end
end

end #module Parser
