using CloudBase, Test, CloudBase.CloudTest, JSON3, Dates, HTTP
using CloudBase: AWS, Azure

const x32bit = Sys.WORD_SIZE == 32

@testset "AWSSigV4" begin
    file = abspath(joinpath(dirname(pathof(CloudBase)), "../test/resources/awsSig4Cases.json"))
    cases = JSON3.read(read(file))
    configs = copy(cases.config)
    configs[:credentials] = CloudBase.AWSCredentials(configs[:accessKeyId], configs[:secretAccessKey])
    delete!(configs, :accessKeyId)
    delete!(configs, :secretAccessKey)
    debug = false
    knownFailures = (19, 20, 23, 26)
    for (i, case) in enumerate(cases.tests.all)
        println("testing AWSSig4 case = $(case.name), i = $i")
        req = HTTP.Request(case.request.method, case.request.path, case.request.headers, case.request.body; url=HTTP.URI(case.request.uri))
        CloudBase.awssign!(req; x_amz_date=DateTime(2015, 8, 30, 12, 36), includeContentSha256=false, debug=debug, configs...)
        if i in knownFailures
            @test_broken HTTP.header(req, "Authorization") == case.authz
        else
            @test HTTP.header(req, "Authorization") == case.authz
        end
    end
end

@testset "AWSSigV2" begin
    req = HTTP.Request("GET", "/?Action=DescribeJobFlows"; url=HTTP.URI("https://elasticmapreduce.amazonaws.com?Action=DescribeJobFlows"))
    credentials = CloudBase.AWSCredentials("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    CloudBase.awssignv2!(req; credentials, timestamp=DateTime(2011, 10, 3, 15, 19, 30), version="2009-03-31")
    @test req.target ==
        "?AWSAccessKeyId=AKIAIOSFODNN7EXAMPLE&Action=DescribeJobFlows&SignatureMethod=HmacSHA256&SignatureVersion=2&Timestamp=2011-10-03T15%3A19%3A30&Version=2009-03-31&Signature=i91nKc4PWAt0JJIdXwz9HxZCJDdiy6cf%2FMj6vPxyYIs%3D"
    req = HTTP.Request("POST", "/", [], Dict("Action" => "DescribeJobFlows"); url=HTTP.URI("https://elasticmapreduce.amazonaws.com"))
    CloudBase.awssignv2!(req; credentials, timestamp=DateTime(2011, 10, 3, 15, 19, 30), version="2009-03-31")
    @test req.body["Signature"] == "wseguMzBRgA/4/fan8ZwEa0PIF+ws4WFbTJcG1ts5RY="
end

@time @testset "AWS" begin
    config = Ref{Any}()
    Minio.with(startupDelay=3) do conf
        config[] = conf
        credentials, bucket = conf
        csv = "a,b,c\n1,2,3\n4,5,$(rand())"
        AWS.put("$(bucket.baseurl)test.csv", [], csv; service="s3", credentials)
        resp = AWS.get("$(bucket.baseurl)test.csv"; service="s3", credentials)
        @test String(resp.body) == csv
    end
    @test !isdir(config[].dir)
    @test success(config[].process)
    # test public access
    Minio.with(startupDelay=3, public=true) do conf
        credentials, bucket = conf
        csv = "a,b,c\n1,2,3\n4,5,$(rand())"
        AWS.put("$(bucket.baseurl)test.csv", [], csv; service="s3")
        resp = AWS.get("$(bucket.baseurl)test.csv"; service="s3")
        @test String(resp.body) == csv
        # list is public
        resp = AWS.get("$(bucket.baseurl)?list-type=2"; service="s3")
        @test resp.status == 200
        # delete is also public
        resp = AWS.delete("$(bucket.baseurl)test.csv"; service="s3")
        @test resp.status == 204
    end
end

if !x32bit
@time @testset "Azure" begin
    config = Ref{Any}()
    Azurite.with(startupDelay=3) do conf
        config[] = conf
        credentials, container = conf
        csv = "a,b,c\n1,2,3\n4,5,$(rand())"
        Azure.put("$(container.baseurl)test", ["x-ms-blob-type" => "BlockBlob"], csv; credentials)
        resp = Azure.get("$(container.baseurl)test"; credentials)
        @test String(resp.body) == csv
        # test SAS generation
        # account-level
        url = "$(container.baseurl)test2"
        key = credentials.auth.key
        sas = CloudBase.generateAccountSASURI(url, key; signedPermission=CloudBase.SignedPermission("rw"))
        resp = HTTP.put(sas, ["x-ms-blob-type" => "BlockBlob"], csv; require_ssl_verification=false)
        resp = HTTP.get(sas; require_ssl_verification=false)
        @test String(resp.body) == csv
        # service-level
        url = "$(container.baseurl)test3"
        sas = CloudBase.generateServiceSASURI(url, key; signedPermission=CloudBase.SignedPermission("rw"))
        resp = HTTP.put(sas, ["x-ms-blob-type" => "BlockBlob"], csv; require_ssl_verification=false)
        resp = HTTP.get(sas; require_ssl_verification=false)
        @test String(resp.body) == csv
    end
    @test !isdir(config[].dir)
    @test success(config[].process)
    # test public access
    Azurite.with(startupDelay=3, public=true) do conf
        credentials, container = conf
        csv = "a,b,c\n1,2,3\n4,5,$(rand())"
        # have to supply credentials for put since "public" is only for get
        Azure.put("$(container.baseurl)test", ["x-ms-blob-type" => "BlockBlob"], csv; credentials)
        resp = Azure.get("$(container.baseurl)test")
        @test String(resp.body) == csv
        # list is public
        resp = Azure.get("$(container.baseurl)?comp=list&restype=container")
        @test resp.status == 200
        # but delete also requires credentials
        Azure.delete("$(container.baseurl)test"; credentials)
    end
end
end

@testset "Concurrent Minio/Azurite test servers" begin
    mconfigs = Vector{Any}(undef, 10)
    aconfigs = Vector{Any}(undef, 10)
    @sync for i = 1:10
        @async Minio.with(startupDelay=3) do conf
            mconfigs[i] = conf
            credentials, bucket = conf
            csv = "a,b,c\n1,2,3\n4,5,$(rand())"
            AWS.put("$(bucket.baseurl)test.csv", [], csv; service="s3", credentials)
            resp = AWS.get("$(bucket.baseurl)test.csv"; service="s3", credentials)
            @test String(resp.body) == csv
        end
        if !x32bit
            @async Azurite.with(startupDelay=3) do conf
                aconfigs[i] = conf
                credentials, container = conf
                csv = "a,b,c\n1,2,3\n4,5,$(rand())"
                Azure.put("$(container.baseurl)test", ["x-ms-blob-type" => "BlockBlob"], csv; credentials)
                resp = Azure.get("$(container.baseurl)test"; credentials)
                @test String(resp.body) == csv
            end
        end
    end
    for i = 1:10
        @test !isdir(mconfigs[i].dir)
        @test success(mconfigs[i].process)
        if !x32bit
            @test !isdir(aconfigs[i].dir)
            @test success(aconfigs[i].process)
        end
    end
end

@testset "AWS ECS Task" begin
    ECS.with() do
        CloudBase.reloadECSCredentials!("http://127.0.0.1")
        @test get(CloudBase.AWS_CONFIGS, "aws_session_token", "") == "ECS_TOKEN"
    end
end

@testset "AWS EC2" begin
    EC2.with() do
        CloudBase.reloadEC2Credentials!("127.0.0.1", 50397)
        @test get(CloudBase.AWS_CONFIGS, "aws_session_token", "") == "EC2_TOKEN"
    end
end

@testset "AzureVM" begin
    AzureVM.with() do
        CloudBase.reloadAzureVMCredentials!("http://127.0.0.1:50398")
        @test !isempty(get(CloudBase.AZURE_CONFIGS, "sas_token", ""))
    end
end
