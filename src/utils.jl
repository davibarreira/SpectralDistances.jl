function twoD(X)
    X = X .- mean(X,dims=1)
    X = X ./ std(X,dims=1)
    s = svd(X)
    Y = s.U[:,1:2]#.*s.S[1:2]'
    Y[:,1], Y[:,2]
end

function threeD(X)
    X = X .- mean(X,dims=1)
    X = X ./ std(X,dims=1)
    s = svd(X)
    Y = s.U[:,1:3]#.*s.S[1:2]'
    Y[:,1], Y[:,2], Y[:,3]
end


s1(x, dims=:) = x./sum(x, dims=dims)
n1(x) = x./norm(x)
function v1(x, dims=:)
    x = x .- mean(x, dims=dims)
    x .= x./std(x, dims=dims)
end

function bp_filter(x, passband)
    responsetype = Bandpass(passband..., fs=1)
    designmethod = Butterworth(2)
    filt(digitalfilter(responsetype, designmethod), x)
end

function lp_filter(x, cutoff)
    responsetype = Lowpass(cutoff, fs=1)
    designmethod = Butterworth(2)
    filt(digitalfilter(responsetype, designmethod), x)
end


@inline nograd(x) = Flux.data(x)
