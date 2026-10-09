unit AppStrings;

// Centralized Simplified Chinese UI strings.
//
// Every string is written with #$XXXX escapes so that the source files stay pure
// ASCII. Delphi reads a BOM-less .pas using the system code page, so literal CJK
// bytes in a source file are a real mojibake risk. Escapes remove that risk
// entirely and keep the UI text independent of editor and compiler settings.
//
// Decoding table for the escapes used below:
//   #$8BA2 #$9605 = ding yue            (subscription)
//   #$7ACB #$5373 #$66F4 #$65B0 = update now
//   #$81EA #$52A8 #$66F4 #$65B0 = auto update
//   #$4E0A #$6B21 #$66F4 #$65B0 = last updated
//   #$6DFB #$52A0 = add                 #$5220 #$9664 = delete
//   #$6253 #$5F00 = open                #$76EE #$5F55 = directory
//   #$66F4 #$591A = more                #$9000 #$51FA = quit
//   #$5185 #$6838 = core                #$91CD #$542F = restart
//   #$5F00 #$673A #$542F #$52A8 = start with Windows
//   #$8FD0 #$884C #$4E2D = running      #$5DF2 #$505C #$6B62 = stopped
//   #$542F #$52A8 = starting            #$5931 #$8D25 = failed
//   #$5DF2 #$7528 = used                #$5230 #$671F = expires
//   #$4ECE #$672A = never               #$672A #$77E5 = unknown
//
// Selector tags and outbound names come from the user's own sing-box config and
// must never be translated.

interface

const
  APP_NAME = 'JieJieBox';
  APP_NAME_WINDOWS = 'JieJieBox for Windows';
  APP_HOMEPAGE = 'https://github.com/Piggy-Cat-bit-shadow/sing-box-drover';

  // --- core status -----------------------------------------------------------
  STATUS_RUNNING = #$25CF + ' ' + #$8FD0 + #$884C + #$4E2D;
  STATUS_STARTING = #$25CC + ' ' + #$542F + #$52A8 + #$4E2D + '...';
  STATUS_STOPPED = #$25CF + ' ' + #$5DF2 + #$505C + #$6B62;
  STATUS_STOPPING = #$25CC + ' ' + #$6B63 + #$5728 + #$505C + #$6B62;
  STATUS_FAILED = #$25CF + ' ' + #$542F + #$52A8 + #$5931 + #$8D25;

  // --- top level menu -------------------------------------------------------
  MENU_SUBSCRIPTIONS = #$8BA2 + #$9605;
  MENU_UPDATE_NOW = #$7ACB + #$5373 + #$66F4 + #$65B0;
  MENU_UPDATING = #$66F4 + #$65B0 + #$4E2D + '...';
  MENU_UPDATED_JUST_NOW = #$521A + #$521A + #$66F4 + #$65B0;
  MENU_UPDATE_FAILED = #$66F4 + #$65B0 + #$5931 + #$8D25;
  MENU_AUTO_UPDATE = #$81EA + #$52A8 + #$66F4 + #$65B0;
  MENU_LAST_UPDATED = #$4E0A + #$6B21 + #$66F4 + #$65B0;
  MENU_NEVER = #$4ECE + #$672A;
  MENU_ADD_SUBSCRIPTION = #$6DFB + #$52A0 + #$8BA2 + #$9605 + '...';
  MENU_OPEN_PROFILES_DIR = #$6253 + #$5F00 + #$8BA2 + #$9605 + #$76EE + #$5F55;
  MENU_NO_SUBSCRIPTION = '(' + #$65E0 + #$8BA2 + #$9605 + ')';
  MENU_DELETE_SUBSCRIPTION = #$5220 + #$9664;

  MENU_TRAFFIC_USED = #$5DF2 + #$7528;
  MENU_TRAFFIC_EXPIRES = #$5230 + #$671F;

  MENU_MORE = #$66F4 + #$591A;
  MENU_CORE_VERSION = #$5185 + #$6838;
  MENU_CORE_VERSION_UNKNOWN = #$672A + #$77E5;
  MENU_RESTART_CORE = #$91CD + #$542F + #$5185 + #$6838;
  MENU_AUTOSTART = #$5F00 + #$673A + #$542F + #$52A8;
  MENU_GITHUB = 'GitHub';
  MENU_QUIT = #$9000 + #$51FA;

  // --- dialogs --------------------------------------------------------------
  DIALOG_ADD_TITLE = #$6DFB + #$52A0 + #$8BA2 + #$9605;
  DIALOG_ADD_NAME_PROMPT = #$540D + #$79F0;
  DIALOG_ADD_URL_PROMPT = 'URL';
  DIALOG_DELETE_TITLE = #$5220 + #$9664 + #$8BA2 + #$9605;
  DIALOG_ACTIVE_CANNOT_DELETE = #$5F53 + #$524D + #$4F7F + #$7528 + #$4E2D + #$7684 + #$8BA2 + #$9605 + #$4E0D + #$80FD + #$5220 + #$9664 + #$FF0C + #$8BF7 + #$5148 + #$5207 + #$6362 + #$5230 + #$5176 + #$4ED6 + #$8BA2 + #$9605 + #$3002;
  DIALOG_DELETE_FAILED = #$5220 + #$9664 + #$8BA2 + #$9605 + #$5931 + #$8D25 + #$3002;
  DIALOG_DELETE_CONFIRM = #$786E + #$5B9A + #$5220 + #$9664 + #$8FD9 + #$4E2A + #$8BA2 + #$9605 + #$5417 + #$FF1F;
  DIALOG_OPEN_DIR_FAILED = #$65E0 + #$6CD5 + #$6253 + #$5F00 + #$8BA2 + #$9605 + #$76EE + #$5F55 + #$3002;
  DIALOG_BAD_URL = #$8BF7 + #$8F93 + #$5165 + #$6709 + #$6548 + #$7684 + ' http:
  DIALOG_ADD_FAILED = #$6DFB + #$52A0 + #$8BA2 + #$9605 + #$5931 + #$8D25;
  DIALOG_TITLE_INFO = #$63D0 + #$793A;
  DIALOG_TITLE_ERROR = #$9519 + #$8BEF;
  DIALOG_SUBSCRIBE_FAILED = #$8BA2 + #$9605 + #$66F4 + #$65B0 + #$5931 + #$8D25;
  // The subscription was updated but the active subscription was left alone.
  DIALOG_SUBSCRIBE_UPDATED_KEPT = #$8BA2 + #$9605 + #$5DF2 + #$66F4 + #$65B0 + #$FF0C + #$4ECD + #$4F7F + #$7528 + #$5F53 + #$524D + #$8BA2 + #$9605 + #$3002;
  // Another update for the same subscription is already running.
  DIALOG_SUBSCRIBE_BUSY = #$8BE5 + #$8BA2 + #$9605 + #$6B63 + #$5728 + #$66F4 + #$65B0 + #$4E2D + #$FF0C + #$8BF7 + #$7A0D + #$540E + #$518D + #$8BD5 + #$3002;
  DIALOG_CORE_START_FAILED = #$5185 + #$6838 + #$542F + #$52A8 + #$5931 + #$8D25;
  DIALOG_PROXY_FAILED = #$8BBE + #$7F6E + ' Windows ' + #$7CFB + #$7EDF + #$4EE3 + #$7406 + #$5931 + #$8D25 + #$3002;
  DIALOG_UAC_DECLINED = #$672A + #$83B7 + #$5F97 + #$7BA1 + #$7406 + #$5458 + #$6743 + #$9650 + #$3002 + #$914D + #$7F6E + #$4E2D + #$5305 + #$542B + ' TUN ' + #$5165 + #$7AD9 + #$FF0C + #$5FC5 + #$987B + #$4EE5 + #$7BA1 + #$7406 + #$5458 + #$8EAB + #$4EFD + #$8FD0 + #$884C + #$3002;
  DIALOG_SINGLE_INSTANCE = #$5DF2 + #$6709 + #$4E00 + #$4E2A + ' ' + APP_NAME + ' ' + #$5B9E + #$4F8B + #$5728 + #$8FD0 + #$884C + #$3002;
  DIALOG_FATAL_PREFIX = 'JieJieBox: ';

implementation

end.
