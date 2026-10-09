object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'JieJieBox'
  ClientHeight = 278
  ClientWidth = 412
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  TextHeight = 15
  object PopupMenu: TPopupMenu
    AutoHotkeys = maManual
    Left = 248
    Top = 40
    object miStatus: TMenuItem
      Caption = '...'
      Enabled = False
    end
    object miSubscriptions: TMenuItem
      Caption = '...'
      object miSubProfilesEnd: TMenuItem
        Caption = '-'
      end
      object miUpdateNow: TMenuItem
        Caption = '...'
        OnClick = miUpdateNowClick
      end
      object miAutoUpdate: TMenuItem
        Caption = '...'
        OnClick = miAutoUpdateClick
      end
      object miLastUpdated: TMenuItem
        Caption = '...'
        Enabled = False
      end
      object miTraffic: TMenuItem
        Caption = '...'
        Enabled = False
        Visible = False
      end
      object miExpire: TMenuItem
        Caption = '...'
        Enabled = False
        Visible = False
      end
      object miSubSeparator: TMenuItem
        Caption = '-'
      end
      object miAddSubscription: TMenuItem
        Caption = '...'
        OnClick = miAddSubscriptionClick
      end
      object miOpenProfilesDir: TMenuItem
        Caption = '...'
        OnClick = miOpenProfilesDirClick
      end
    end
    object miSelectors: TMenuItem
      Caption = '...'
    end
    object miBeforeMore: TMenuItem
      Caption = '-'
    end
    object miMore: TMenuItem
      Caption = '...'
      object miCoreVersion: TMenuItem
        Caption = '...'
        Enabled = False
      end
      object miRestartCore: TMenuItem
        Caption = '...'
        OnClick = miRestartCoreClick
      end
      object miAutostart: TMenuItem
        Caption = '...'
        Enabled = False
        OnClick = miAutostartClick
      end
      object miHomepage: TMenuItem
        Caption = 'GitHub'
        OnClick = miHomepageClick
      end
    end
    object miQuit: TMenuItem
      Caption = '...'
      OnClick = miQuitClick
    end
  end
  object Timer: TTimer
    Enabled = False
    OnTimer = TimerTimer
    Left = 320
    Top = 40
  end
end
