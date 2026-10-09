unit SingBoxConfig;

// Metadata parsed out of a sing-box config.
//
// IMPORTANT: this record is GUI-side metadata only. The bytes that are handed to
// the core always come from the original file/profile text. This unit never
// produces a rewritten config.

interface

uses
  SingBoxBpf;

type
  TConfigSourceFormat = (csfJson, csfBpf);

  TConfigSelector = record
    name: string;
    outbounds: TArray<string>;
    defaultIndex: integer;
    defaultName: string;
  end;

  TConfigSelectors = TArray<TConfigSelector>;

  TClashApiConfig = record
    externalController: string;
    secret: string;

    function IsConfigured: boolean;
  end;

  TConfigSource = record
    filePath: string;
    format: TConfigSourceFormat;
    jsonText: string;
    bpfProfile: TBpfProfile;

    function isBpf: boolean;
  end;

  // Subscription traffic counters read from the `Subscription-Userinfo`
  // response header. All fields are 0 when the header is missing.
  TSubscriptionUserInfo = record
    upload: int64;
    download: int64;
    total: int64;
    expire: int64;

    function HasTraffic: boolean;
    function HasExpire: boolean;
  end;

  TSingBoxConfig = record
    clashApi: TClashApiConfig;
    selectors: TConfigSelectors;
    proxyHost: string;
    proxyPort: integer;
    hasTunInbound: boolean;
    hasHttpInbound: boolean;
  end;

implementation

function TConfigSource.isBpf: boolean;
begin
  result := format = csfBpf;
end;

function TClashApiConfig.IsConfigured: boolean;
begin
  result := externalController <> '';
end;

function TSubscriptionUserInfo.HasTraffic: boolean;
begin
  result := total > 0;
end;

function TSubscriptionUserInfo.HasExpire: boolean;
begin
  result := expire > 0;
end;

end.
