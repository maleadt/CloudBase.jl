module CloudBase

export CloudTest

using Dates, Base64, Sockets
using HTTP, URIs, SHA, MD5, LoggingExtras, Figgy

"""
    CloudCredentials

Abstract type that specific cloud providers subtype to represent
a "credentials" object. This is passed to cloud request methods
as the `credentials` keyword argument and is used to authenticate
cloud requests. See [`AWS.Credentials`](@ref) and
[`Azure.Credentials`](@ref) for examples.
"""
abstract type CloudCredentials end

"""
    AbstractStore

Abstract type that specific cloud providers subtype to represent
a "store". This is used to construct cloud urls and perform
operations on cloud objects. See [`AWS.Bucket`](@ref) and
[`Azure.Container`](@ref) for examples.
"""
abstract type AbstractStore end

_some(x, y) = x === nothing ? y : x

# utility to check if an ip:port can be connected to
function canconnect(ip, port, timeout=0.01)
    tcp = Sockets.TCPSocket()
    try
        Sockets.connect!(tcp, ip, port)
        sleep(timeout)
        return tcp.status == Base.StatusOpen
    catch
        return false
    finally
        close(tcp)
    end
end

# expiration check for both AWS.Credentials and Azure.Credentials
expired(x) = x.expiration !== nothing && Dates.now(Dates.UTC) > (x.expiration - x.expireThreshold)

include("aws.jl")
include("azure.jl")

# custom stream layer to be included right before actual request
# is sent to ensure header timestamps are as correct as possible
function cloudsignlayer(handler)
    function cloudsign(stream; aws::Bool=false, awsv2::Bool=false, azure::Bool=false, kw...)
        req = stream.message.request
        if awsv2
            awssignv2!(req; kw...)
        elseif aws
            awssign!(req; kw...)
        end
        azure && azuresign!(req; kw...)
        return handler(stream; kw...)
    end
end

"""
    CloudBase.AWS

Submodule that contains a custom HTTP.jl client for performing AWS requests.
For authenticated requests, an [`AWS.Credentials`](@ref) object should be passed
as the `credentials` keyword argument. Otherwise, the request methods operate
just like the `HTTP` equivalents and supports all the same keyword arguments.
"""
module AWS

using HTTP
import ..cloudsignlayer, ..AWSCredentials, ..AbstractStore, ..AWS_DEFAULT_REGION

awslayer(handler) = (req; kw...) -> handler(req; kw..., aws=true)

HTTP.@client (first=(awslayer,), last=()) (first=(), last=(cloudsignlayer,))

const DOCS = """
    AWS.get(url, headers, body; credentials, awsv2=false, kw...)
    AWS.put(url, headers, body; kw...)
    AWS.post(url, headers, body; kw...)
    AWS.delete(url, headers, body; kw...)
    AWS.head(url, headers; kw...)
    AWS.patch(url, headers, body; kw...)
    AWS.request(method, url, headers, body; kw...)
    AWS.open(method, url, headers[, body]; kw...)

HTTP.jl client methods that additionally *each* take a `credentials` keyword argument,
which should be an `AWS.Credentials` object. To have AWSV2 request signing instead of AWSV4,
pass `awsv2=true`. If the `credentials` object was inferred from the environment and is set
to expire soon, it will be refreshed automatically.

Otherwise, these methods operate exactly like their `HTTP.method` counterparts, accepting
all the same positional and keyword arguments.

Note that due to the nature of AWS signing requirements, streaming request bodies are not supported.
"""
for method in (:get, :put, :post, :delete, :head, :patch, :request, :open)
    @eval begin
        @doc $DOCS AWS.$method(args...; kw...)
    end
end

"""
    CloudBase.AWS.Credentials([profile]; expireThreshold=Dates.Minute(5))
    CloudBase.AWS.Credentials(access_key_id, secret_access_key[, session_token])

Credentials object used for authenticating AWS requests. By default, calling `AWS.Credentials()` or
`AWS.Credentials(profile)`, will search the normal AWS credential locations (files, environment variables, etc.)
to find the access key and secret. Otherwise, the 2nd constructor allows providing the access key & secret directly,
ignoring any existing configurations. If a profile includes a `role_arn`, an STS request will be made with
source credentials to get temporary credentials. AWS EC2 and ECS credentials are also automatically detected and
retrieved. Temporary credentials via EC2, EC2, or role_arn that include expirations will automatically be refreshed
`expireThreshold` before expiration when a request is made.
"""
const Credentials = AWSCredentials

"""
    CloudBase.AWS.Bucket(name, [region="us-east-1"]; accelerate::Bool=false)

Object representation of an AWS storage bucket with the given `name`. If not provided,
the `region` is assumed to be "us-east-1". Aliased in the CloudStore.jl package as `S3.Bucket`.
If `accelerate=true` is passed, requests with the bucket will use the `bucket.s3-accelerate.amazonaws.com`
style url instead of the traditional `bucket.s3.amazonaws.com`.
"""
struct Bucket <: AbstractStore
    name::String
    baseurl::String

    function Bucket(name::String, region::String=AWS_DEFAULT_REGION; accelerate::Bool=false, host::Union{Nothing, String}=nothing)
        baseurl = host === nothing ? "https://$name.s3$(accelerate ? "-accelerate" : "").$region.amazonaws.com/" : "$host/$name/"
        return new(name, baseurl)
    end
end

end # module AWS

"""
    CloudBase.Azure

Submodule that contains a custom HTTP.jl client for performing Azure requests.
For authenticated requests, an [`Azure.Credentials`](@ref) object should be passed
as the `credentials` keyword argument. Otherwise, the request methods operate
just like the `HTTP` equivalents and supports all the same keyword arguments.
"""
module Azure

using HTTP
import ..cloudsignlayer, ..AzureCredentials, ..AbstractStore

azurelayer(handler) = (req; kw...) -> handler(req; azure=true, aws=false, awsv2=false, require_ssl_verification=req.url.host != "127.0.0.1", kw...)

HTTP.@client (first=(azurelayer,), last=()) (first=(), last=(cloudsignlayer,))

const DOCS = """
    Azure.get(url, headers, body; credentials, kw...)
    Azure.put(url, headers, body; kw...)
    Azure.post(url, headers, body; kw...)
    Azure.delete(url, headers, body; kw...)
    Azure.head(url, headers; kw...)
    Azure.patch(url, headers, body; kw...)
    Azure.request(method, url, headers, body; kw...)
    Azure.open(method, url, headers[, body]; kw...)

HTTP.jl client methods that additionally *each* take a `credentials` keyword argument,
which should be an `Azure.Credentials` object. If the `credentials` object was inferred
from the environment and is set to expire soon, it will be refreshed automatically.

Otherwise, these methods operate exactly like their `HTTP.method` counterparts, accepting
all the same positional and keyword arguments.
"""
for method in (:get, :put, :post, :delete, :head, :patch, :request, :open)
    @eval begin
        @doc $DOCS Azure.$method(args...; kw...)
    end
end

"""
    CloudBase.Azure.Credentials(; expireThreshold=Dates.Minute(5))
    CloudBase.Azure.Credentials(account, shared_key)
    CloudBase.Azure.Credentials(access_token)

Credentials object used for authenticating Azure requests. By default, calling `Azure.Credentials()`
will search the normal Azure credential locations (files, environment variables, etc.)
to find the account, shared key, or access_token. Otherwise, the 2nd constructor allows providing the
account & shared key or access token directly, ignoring any existing configurations. Azure VM credentials
are also automatically detected and retrieved. Temporary credentials via Azure VM that include expirations
will automatically be refreshed `expireThreshold` before expiration when a request is made.
"""
const Credentials = AzureCredentials

"""
    CloudBase.Azure.Container(name, account)

Object representation of an Azure storage bucket with the given `name` and `account`.
Aliased in the CloudStore.jl package as `Blobs.Container`.
"""
struct Container <: AbstractStore
    name::String
    baseurl::String

    function Container(name::String, account::String; host::Union{Nothing, String}=nothing)
        baseurl = host === nothing ? "https://$account.blob.core.windows.net/$name/" : "$host/$account/$name/"
        return new(name, baseurl)
    end
end

end # module Azure

include("CloudTest.jl")

end # module CloudBase
