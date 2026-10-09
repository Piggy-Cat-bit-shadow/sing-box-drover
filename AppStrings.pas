unit AppStrings;

// Centralized Simplified Chinese UI strings.
//
// All non-ASCII text is expressed with $ escapes so that the literal contents of
// every source file stay pure ASCII. This makes the UI text independent of the
// editor/compiler source charset and avoids mojibake.
//
// Selector tags and outbound names come from the user's own sing-box config and
// must never be translated.

interface

const
  APP_NAME = 'JieJieBox';
  APP_NAME_WINDOWS = 'JieJieBox for Windows';
  APP_HOMEPAGE = 'https://github.com/Piggy-Cat-bit-shadow/sing-box-drover';

  // --- core status -----------------------------------------------------------
  STATUS_RUNNING = #$25CF + ' ' + #$8FD0 + #$884C + #$4E2D; // "● 运行中"
  STATUS_STARTING = #$25CC + ' ' + #$542F + #$52A8 + #$4E2D + '...'; // "◌ 启动中..."
  STATUS_STOPPED = #$25CF + ' ' + #$5DF2 + #$505C + #$6B62; // "● 已停止"
  STATUS_STOPPING = #$25CC + ' ' + #$6B63 + #$5728 + #$505C + #$6B62; // "◌ 正在停止"
  STATUS_FAILED = #$25CF + ' ' + #$542F + #$52A8 + #$5931 + #$8D25; // "● 启动失败"

  // --- top level menu -------------------------------------------------------
  MENU_SUBSCRIPTIONS = #$8BA2 + #$9605; // "订阅"
  MENU_UPDATE_NOW = #$7ACB + #$5373 + #$66F4 + #$65B0; // "立即更新"
  MENU_UPDATING = #$66F4 + #$65B0 + #$4E2D + '...'; // "更新中..."
  MENU_UPDATED_JUST_NOW = #$521A + #$521A + #$66F4 + #$65B0; // "刚刚更新"
  MENU_UPDATE_FAILED = #$66F4 + #$65B0 + #$5931 + #$8D25; // "更新失败"
  MENU_AUTO_UPDATE = #$81EA + #$52A8 + #$66F4 + #$65B0; // "自动更新"
  MENU_LAST_UPDATED = #$4E0A + #$6B21 + #$66F4 + #$65B0; // "上次更新"
  MENU_NEVER = #$4ECE + #$672A; // "从未"
  MENU_ADD_SUBSCRIPTION = #$6DFB + #$52A0 + #$8BA2 + #$9605 + '...'; // "添加订阅..."
  MENU_OPEN_PROFILES_DIR = #$6253 + #$5F00 + #$8BA2 + #$9605 + #$76EE + #$5F55; // "打开订阅目录"
  MENU_NO_SUBSCRIPTION = '(' + #$65E0 + #$8BA2 + #$9605 + ')'; // "(无订阅)"
  MENU_DELETE_SUBSCRIPTION = #$5220 + #$9664; // "删除"

  MENU_TRAFFIC_USED = #$5DF2 + #$7528; // "已用"
  MENU_TRAFFIC_EXPIRES = #$5230 + #$671F; // "到期"

  MENU_MORE = #$66F4 + #$591A; // "更多"
  MENU_CORE_VERSION = #$5185 + #$6838; // "内核"
  MENU_CORE_VERSION_UNKNOWN = #$672A + #$77E5; // "未知"
  MENU_RESTART_CORE = #$91CD + #$542F + #$5185 + #$6838; // "重启内核"
  MENU_AUTOSTART = #$5F00 + #$673A + #$542F + #$52A8; // "开机启动"
  MENU_GITHUB = 'GitHub';
  MENU_QUIT = #$9000 + #$51FA; // "退出"

  // --- dialogs --------------------------------------------------------------
  DIALOG_ADD_TITLE = #$6DFB + #$52A0 + #$8BA2 + #$9605; // "添加订阅"
  DIALOG_ADD_NAME_PROMPT = #$540D + #$79F0; // "名称"
  DIALOG_ADD_URL_PROMPT = 'URL';
  DIALOG_DELETE_TITLE = #$5220 + #$9664 + #$8BA2 + #$9605; // "删除订阅"
  DIALOG_ACTIVE_CANNOT_DELETE = #$5F53 + #$524D + #$4F7F + #$7528 + #$4E2D + #$7684 + #$8BA2 + #$9605 + #$4E0D + #$80FD + #$5220 + #$9664 + #$FF0C + #$8BF7 + #$5148 + #$5207 + #$6362 + #$5230 + #$5176 + #$4ED6 + #$8BA2 + #$9605 + #$3002; // "当前使用中的订阅不能删除，请先切换到其他订阅。"
  DIALOG_DELETE_FAILED = #$5220 + #$9664 + #$8BA2 + #$9605 + #$5931 + #$8D25 + #$3002; // "删除订阅失败。"
  DIALOG_DELETE_CONFIRM = #$786E + #$5B9A + #$5220 + #$9664 + #$8FD9 + #$4E2A + #$8BA2 + #$9605 + #$5417 + #$FF1F; // "确定删除这个订阅吗？"
  DIALOG_OPEN_DIR_FAILED = #$65E0 + #$6CD5 + #$6253 + #$5F00 + #$8BA2 + #$9605 + #$76EE + #$5F55 + #$3002; // "无法打开订阅目录。"
  DIALOG_BAD_URL = #$8BF7 + #$8F93 + #$5165 + #$6709 + #$6548 + #$7684 + ' http:// ' + #$6216 + ' https:// ' + #$8BA2 + #$9605 + #$5730 + #$5740 + #$3002; // "请输入有效的 http:// 或 https:// 订阅地址。"
  DIALOG_ADD_FAILED = #$6DFB + #$52A0 + #$8BA2 + #$9605 + #$5931 + #$8D25; // "添加订阅失败"
  DIALOG_TITLE_INFO = #$63D0 + #$793A; // "提示"
  DIALOG_TITLE_ERROR = #$9519 + #$8BEF; // "错误"
  DIALOG_SUBSCRIBE_FAILED = #$8BA2 + #$9605 + #$66F4 + #$65B0 + #$5931 + #$8D25; // "订阅更新失败"
  DIALOG_CORE_START_FAILED = #$5185 + #$6838 + #$542F + #$52A8 + #$5931 + #$8D25; // "内核启动失败"
  DIALOG_PROXY_FAILED = #$8BBE + #$7F6E + ' Windows ' + #$7CFB + #$7EDF + #$4EE3 + #$7406 + #$5931 + #$8D25 + #$3002; // "设置 Windows 系统代理失败。"
  DIALOG_UAC_DECLINED = #$672A + #$83B7 + #$5F97 + #$7BA1 + #$7406 + #$5458 + #$6743 + #$9650 + #$3002 + #$914D + #$7F6E + #$4E2D + #$5305 + #$542B + ' TUN ' + #$5165 + #$7AD9 + #$FF0C + #$5FC5 + #$987B + #$4EE5 + #$7BA1 + #$7406 + #$5458 + #$8EAB + #$4EFD + #$8FD0 + #$884C + #$3002; // "未获得管理员权限。配置中包含 TUN 入站，必须以管理员身份运行。"
  DIALOG_SINGLE_INSTANCE = #$5DF2 + #$6709 + #$4E00 + #$4E2A + ' ' + APP_NAME + ' ' + #$5B9E + #$4F8B + #$5728 + #$8FD0 + #$884C + #$3002; // "已有一个 JieJieBox 实例在运行。"
  DIALOG_FATAL_PREFIX = 'JieJieBox: ';

implementation

end.
