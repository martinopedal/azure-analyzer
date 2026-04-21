# tests/viewer/Viewer.Security.Tests.ps1
#
# Placeholder negative-test suite for the viewer threat model (#430).
# Every Describe block here is -Skip pending the implementation PR (Foundation #435 +
# downstream tier-4 work). The names and shapes are the binding contract:
# implementation must un-skip, not rename.
#
# Threat model reference: docs/design/viewer-threat-model.md  (defenses D1..D12)

Describe 'Viewer.Security.LoopbackBind (D1)' -Skip {
    It 'binds 127.0.0.1 only and refuses non-loopback connections' {
        # impl: bring up viewer, probe 0.0.0.0 + LAN IP, assert refused
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.RandomPort (D2)' -Skip {
    It 'selects a random free port in 7000-7099 per launch' {
        # impl: launch 5x, assert port set has > 1 distinct value
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.HostHeader (D3)' -Skip {
    It 'rejects requests whose Host header is not loopback' {
        # impl: send Host: evil.com, expect 421
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.OriginHeader (D4)' -Skip {
    It 'rejects cross-origin requests' {
        # impl: send Origin: https://evil.com, expect 403
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.CorsDisabled (D5)' -Skip {
    It 'emits no Access-Control-* headers' {
        # impl: assert response headers contain none
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.CsrfToken (D6)' -Skip {
    It 'rejects POST/PUT/DELETE without a valid X-CSRF-Token' {
        # impl: POST /api/triage with missing + wrong token, expect 403 each
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.SessionToken (D7)' -Skip {
    It 'rejects GET requests with a missing or wrong session token' {
        # impl: GET /api/findings with no token + wrong token, expect 401 each
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.EntityIdValidation (D8)' -Skip {
    It 'rejects path-traversal, HTML, empty, and oversize entity IDs' {
        # impl: Test-EntityIdSafe over a fixture matrix, all -> $false
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.NoArbitraryFileRead (D9)' -Skip {
    It 'serves only allowlisted logical file names' {
        # impl: GET /files/..%2fetc%2fpasswd -> 404; /files/unknown -> 404
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.SessionFileAcl (D10)' -Skip {
    It 'writes .viewer-session.json with mode 0600 / restrictive ACL and 8h TTL' {
        # impl: assert ACL contains only SYSTEM + current user, expiresUtc ~ now+8h
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.ResponseSanitization (D11)' -Skip {
    It 'strips token-shaped strings from API response bodies via Remove-Credentials' {
        # impl: seed finding with synthetic secret, GET, assert pattern absent
        $true | Should -BeTrue
    }
}

Describe 'Viewer.Security.TokenRateLimit (D12)' -Skip {
    It 'returns 429 after 5 failed token attempts within 60s' {
        # impl: 6 wrong tokens in tight loop, assert 6th -> 429 + Retry-After
        $true | Should -BeTrue
    }
}
