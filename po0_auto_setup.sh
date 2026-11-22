#!/bin/sh
# Po0自动申请 (luci-app-po0-auto) OpenWrt / ImmortalWrt 一键安装与卸载脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CRON_FILE="/etc/crontabs/root"
CRON_TAG="# po0-auto-task"

if [ "$(id -u)" -ne 0 ]; then
	printf "${RED}[错误] 请使用 root 权限运行此脚本。${NC}\n"
	exit 1
fi

refresh_luci() {
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
	/etc/init.d/nginx reload >/dev/null 2>&1 || true
}

get_install_status() {
	if [ -f /usr/bin/po0-auto-run ] && [ -f /www/luci-static/resources/view/po0-auto/config.js ]; then
		printf "${GREEN}已安装${NC}"
	else
		printf "${YELLOW}未安装${NC}"
	fi
}

get_cron_status() {
	if [ -f "$CRON_FILE" ] && grep -q "$CRON_TAG" "$CRON_FILE"; then
		local line
		line=$(grep "$CRON_TAG" "$CRON_FILE" | head -n 1 | sed "s/${CRON_TAG}//")
		printf "${GREEN}运行中${NC} (%s)" "$line"
	else
		printf "${YELLOW}未启用${NC}"
	fi
}

install_plugin() {
	printf "\n${CYAN}>>> 开始安装 / 更新 [Po0自动申请] 插件...${NC}\n"

	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		printf "${YELLOW}[提示] 当前系统未检测到 curl 或 wget，建议安装后执行 opkg install curl。${NC}\n"
	fi

	mkdir -p \
		/etc/config \
		/etc/init.d \
		/usr/bin \
		/usr/share/luci/menu.d \
		/usr/share/rpcd/acl.d \
		/www/luci-static/resources/view/po0-auto

	# 1. 初始化 UCI 配置（若已存在则保留原配置和 URL）
	if [ ! -f /etc/config/po0_auto ]; then
cat <<'EOF' > /etc/config/po0_auto
config po0_auto 'main'
	option enabled '0'
	list weekdays '1'
	list weekdays '2'
	list weekdays '3'
	list weekdays '4'
	list weekdays '5'
	list weekdays '6'
	list weekdays '0'
	option hour '04'
	option minute '00'
	option insecure '1'
	option timeout '15'
EOF
	else
		printf "${GREEN}[保留] 检测到已有配置文件 /etc/config/po0_auto，保留原有 URL 与设置。${NC}\n"
	fi

	# 2. 核心静默请求脚本
cat <<'EOF' > /usr/bin/po0-auto-run
#!/bin/sh

. /lib/functions.sh

LOG_FILE="/tmp/po0_auto.log"
MODE="${1:-cron}"
MAX_LINES=200
HAS_URL=0

log_msg() {
	printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$1" >> "$LOG_FILE"
}

trim_log() {
	[ -f "$LOG_FILE" ] || return 0
	local lines
	lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
	if [ "$lines" -gt "$MAX_LINES" ]; then
		tail -n "$MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp.$$" && mv "${LOG_FILE}.tmp.$$" "$LOG_FILE"
	fi
}

visit_url() {
	local raw_url="$1"
	local url
	url=$(printf '%s' "$raw_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[ -z "$url" ] && return 0

	HAS_URL=1
	local err_file="/tmp/po0_auto_err.$$"

	if command -v curl >/dev/null 2>&1; then
		local http_code ret err_msg
		if [ "$INSECURE" = "1" ]; then
			http_code=$(curl -sS -k -L -o /dev/null -w '%{http_code}' --connect-timeout 10 -m "$TIMEOUT" "$url" 2>"$err_file")
		else
			http_code=$(curl -sS -L -o /dev/null -w '%{http_code}' --connect-timeout 10 -m "$TIMEOUT" "$url" 2>"$err_file")
		fi
		ret=$?
		if [ "$ret" -eq 0 ]; then
			log_msg "[成功] HTTP ${http_code} | ${url}"
		else
			err_msg=$(tr '\n' ' ' < "$err_file")
			log_msg "[失败] curl(${ret}): ${err_msg} | ${url}"
		fi
	elif command -v wget >/dev/null 2>&1; then
		local ret err_msg
		if [ "$INSECURE" = "1" ]; then
			wget -q --no-check-certificate -O /dev/null -T "$TIMEOUT" "$url" 2>"$err_file"
		else
			wget -q -O /dev/null -T "$TIMEOUT" "$url" 2>"$err_file"
		fi
		ret=$?
		if [ "$ret" -eq 0 ]; then
			log_msg "[成功] wget OK | ${url}"
		else
			err_msg=$(tr '\n' ' ' < "$err_file")
			log_msg "[失败] wget(${ret}): ${err_msg} | ${url}"
		fi
	else
		log_msg "[失败] 未找到 curl 或 wget，请先安装 curl"
	fi

	rm -f "$err_file"
}

config_load po0_auto
config_get ENABLED main enabled "0"
config_get INSECURE main insecure "1"
config_get TIMEOUT main timeout "15"

case "$TIMEOUT" in
	''|*[!0-9]*) TIMEOUT=15 ;;
esac

if [ "$MODE" = "cron" ] && [ "$ENABLED" != "1" ]; then
	exit 0
fi

config_list_foreach main urls visit_url

if [ "$HAS_URL" -eq 0 ]; then
	log_msg "[跳过] 当前未配置任何 URL"
fi

trim_log
exit 0
EOF
	chmod 755 /usr/bin/po0-auto-run

	# 3. Init 服务脚本
cat <<'EOF' > /etc/init.d/po0_auto
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

CRON_FILE="/etc/crontabs/root"
CRON_TAG="# po0-auto-task"

remove_cron() {
	[ -f "$CRON_FILE" ] || return 0
	if grep -q "$CRON_TAG" "$CRON_FILE"; then
		sed -i "/${CRON_TAG}/d" "$CRON_FILE"
		/etc/init.d/cron restart >/dev/null 2>&1
	fi
}

apply_cron() {
	local enabled weekdays hour minute
	config_load po0_auto
	config_get enabled main enabled "0"
	config_get weekdays main weekdays ""
	config_get hour main hour "04"
	config_get minute main minute "00"

	mkdir -p /etc/crontabs
	[ -f "$CRON_FILE" ] || touch "$CRON_FILE"

	sed -i "/${CRON_TAG}/d" "$CRON_FILE"

	if [ "$enabled" != "1" ]; then
		/etc/init.d/cron restart >/dev/null 2>&1
		return 0
	fi

	hour=$(printf '%s' "$hour" | sed 's/^0*\([0-9]\)/\1/')
	minute=$(printf '%s' "$minute" | sed 's/^0*\([0-9]\)/\1/')
	case "$hour" in ''|*[!0-9]*) hour=4 ;; esac
	case "$minute" in ''|*[!0-9]*) minute=0 ;; esac
	[ "$hour" -gt 23 ] && hour=0
	[ "$minute" -gt 59 ] && minute=0

	local clean_days=""
	local count=0
	local d
	for d in $weekdays; do
		case "$d" in
			7) d="0" ;;
			0|1|2|3|4|5|6) ;;
			*) continue ;;
		esac
		case " $clean_days " in
			*" $d "*) continue ;;
		esac
		clean_days="${clean_days:+$clean_days }$d"
		count=$((count + 1))
	done

	if [ "$count" -eq 0 ]; then
		/etc/init.d/cron restart >/dev/null 2>&1
		return 0
	fi

	local cron_dow
	if [ "$count" -eq 7 ]; then
		cron_dow="*"
	else
		cron_dow=$(printf '%s' "$clean_days" | tr ' ' ',')
	fi

	echo "${minute} ${hour} * * ${cron_dow} /usr/bin/po0-auto-run cron ${CRON_TAG}" >> "$CRON_FILE"
	/etc/init.d/cron restart >/dev/null 2>&1
}

start_service() {
	apply_cron
}

stop_service() {
	remove_cron
}

reload_service() {
	apply_cron
}

service_triggers() {
	procd_add_reload_trigger "po0_auto"
}
EOF
	chmod 755 /etc/init.d/po0_auto

	# 4. 注册 ucitrack，确保 LuCI 点击“保存并应用”立即重载定时任务
	if command -v uci >/dev/null 2>&1 && [ -f /etc/config/ucitrack ]; then
		uci -q delete ucitrack.po0_auto
		uci set ucitrack.po0_auto='po0_auto'
		uci set ucitrack.po0_auto.init='po0_auto'
		uci commit ucitrack
	fi

	# 5. LuCI 菜单注册（挂载在“服务”栏下）
cat <<'EOF' > /usr/share/luci/menu.d/luci-app-po0-auto.json
{
	"admin/services/po0-auto": {
		"title": "Po0自动申请",
		"order": 90,
		"action": {
			"type": "view",
			"path": "po0-auto/config"
		},
		"depends": {
			"acl": [ "luci-app-po0-auto" ],
			"uci": { "po0_auto": true }
		}
	}
}
EOF
	chmod 644 /usr/share/luci/menu.d/luci-app-po0-auto.json

	# 6. RPCD ACL 权限配置
cat <<'EOF' > /usr/share/rpcd/acl.d/luci-app-po0-auto.json
{
	"luci-app-po0-auto": {
		"description": "Grant UCI and execution access for Po0 Auto Apply",
		"read": {
			"uci": [ "po0_auto" ],
			"file": {
				"/tmp/po0_auto.log": [ "read" ],
				"/etc/crontabs/root": [ "read" ]
			}
		},
		"write": {
			"uci": [ "po0_auto" ],
			"file": {
				"/usr/bin/po0-auto-run": [ "exec" ],
				"/tmp/po0_auto.log": [ "write" ]
			}
		}
	}
}
EOF
	chmod 644 /usr/share/rpcd/acl.d/luci-app-po0-auto.json

	# 7. LuCI JS 前端视图
cat <<'EOF' > /www/luci-static/resources/view/po0-auto/config.js
'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('po0_auto'),
			L.resolveDefault(fs.read('/tmp/po0_auto.log'), ''),
			L.resolveDefault(fs.read('/etc/crontabs/root'), '')
		]);
	},

	render: function(data) {
		var logContent = data[1] || '';
		var cronContent = data[2] || '';
		var activeCron = '未启用或尚未生成定时任务';

		cronContent.split('\n').forEach(function(line) {
			if (line.indexOf('# po0-auto-task') !== -1) {
				activeCron = line.replace('# po0-auto-task', '').trim();
			}
		});

		var m, s, o;

		m = new form.Map('po0_auto', 'Po0自动申请',
			'按设定的星期与时间自动静默访问自定义 URL 列表。');

		s = m.section(form.NamedSection, 'main', 'po0_auto');
		s.anonymous = true;
		s.addremove = false;

		s.tab('general', '基本设置');
		s.tab('log', '运行日志');

		// --- Tab 1: 基本设置 ---
		o = s.taboption('general', form.DummyValue, '_cron_status', '当前生效计划');
		o.rawhtml = true;
		o.cfgvalue = function() {
			var safe = activeCron
				.replace(/&/g, '&amp;')
				.replace(/</g, '&lt;')
				.replace(/>/g, '&gt;');
			return '<code>' + safe + '</code>';
		};

		o = s.taboption('general', form.Flag, 'enabled', '开启 Po0自动申请');
		o.rmempty = false;
		o.default = '0';

		o = s.taboption('general', form.MultiValue, 'weekdays', '执行周期（礼拜一 - 礼拜天）',
			'勾选需要执行的星期；礼拜一至礼拜天全部勾选时，将自动按每天执行（Cron 星期位设为 *）。');
		o.value('1', '礼拜一');
		o.value('2', '礼拜二');
		o.value('3', '礼拜三');
		o.value('4', '礼拜四');
		o.value('5', '礼拜五');
		o.value('6', '礼拜六');
		o.value('0', '礼拜天');
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'hour', '定时 - 小时');
		for (var h = 0; h < 24; h++) {
			var hs = (h < 10 ? '0' : '') + h;
			o.value(hs, hs + ' 时');
		}
		o.default = '04';
		o.rmempty = false;

		o = s.taboption('general', form.ListValue, 'minute', '定时 - 分钟');
		for (var min = 0; min < 60; min++) {
			var ms = (min < 10 ? '0' : '') + min;
			o.value(ms, ms + ' 分');
		}
		o.default = '00';
		o.rmempty = false;

		o = s.taboption('general', form.DynamicList, 'urls', '目标 URL 列表',
			'输入需静默访问的完整 URL，点击右侧 "+" 可额外新增多个 URL 输入框。');
		o.placeholder = 'https://xxx.xxx.xxx.xxx/api/firewall/pgnfw_xxxxxxxxxxxxxxxxxxxxxxxx/add';

		o = s.taboption('general', form.Flag, 'insecure', '忽略 SSL 证书校验',
			'目标为 IP 形式的 HTTPS 地址或自签名证书时建议开启（对应 curl -k）。');
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'timeout', '单次请求超时（秒）');
		o.datatype = 'range(3,120)';
		o.default = '15';
		o.rmempty = false;

		o = s.taboption('general', form.Button, '_run_now', '手动测试',
			'点击“保存并应用”后，可在此立即触发一次静默访问以验证接口连通性。');
		o.inputtitle = '立即执行一次';
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal('正在执行', [
				E('p', { 'class': 'spinning' }, '正在静默访问目标 URL 列表，请稍候...')
			]);
			return fs.exec('/usr/bin/po0-auto-run', ['manual']).then(function() {
				return L.resolveDefault(fs.read('/tmp/po0_auto.log'), '');
			}).then(function(newLog) {
				ui.hideModal();
				var logEl = document.getElementById('po0-auto-log-view');
				if (logEl) {
					logEl.value = newLog || '暂无运行日志';
					logEl.scrollTop = logEl.scrollHeight;
				}
				ui.addNotification(null, E('p', '手动执行完成，请切换至“运行日志”查看 HTTP 返回状态。'), 'info');
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', '执行失败：' + (err.message || err)), 'error');
			});
		};

		// --- Tab 2: 运行日志 ---
		o = s.taboption('log', form.DummyValue, '_log_area');
		o.rawhtml = true;
		o.renderWidget = function() {
			var textarea = E('textarea', {
				'id': 'po0-auto-log-view',
				'class': 'cbi-input-textarea',
				'style': 'width: 100%; font-family: monospace; font-size: 12px;',
				'rows': 16,
				'readonly': 'readonly',
				'wrap': 'off'
			}, [ logContent || '暂无运行日志' ]);

			var btnRefresh = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'style': 'margin-right: 8px;',
				'click': ui.createHandlerFn(this, function() {
					return L.resolveDefault(fs.read('/tmp/po0_auto.log'), '').then(function(txt) {
						textarea.value = txt || '暂无运行日志';
						textarea.scrollTop = textarea.scrollHeight;
					});
				})
			}, [ '刷新日志' ]);

			var btnClear = E('button', {
				'class': 'btn cbi-button cbi-button-reset',
				'click': ui.createHandlerFn(this, function() {
					return fs.write('/tmp/po0_auto.log', '').then(function() {
						textarea.value = '暂无运行日志';
					});
				})
			}, [ '清空日志' ]);

			return E('div', { 'style': 'width: 100%;' }, [
				E('div', { 'style': 'margin-bottom: 8px;' }, [ btnRefresh, btnClear ]),
				textarea
			]);
		};

		return m.render();
	}
});
EOF
	chmod 644 /www/luci-static/resources/view/po0-auto/config.js

	# 8. 启用服务并刷新 LuCI 缓存
	/etc/init.d/cron enable >/dev/null 2>&1 || true
	/etc/init.d/cron start >/dev/null 2>&1 || true
	/etc/init.d/po0_auto enable
	/etc/init.d/po0_auto start
	refresh_luci

	printf "${GREEN}>>> [Po0自动申请] 安装完成！${NC}\n"
	printf "请强制刷新 LuCI 浏览器页面（Ctrl+F5），在 [服务 - Po0自动申请] 中配置使用。\n"
}

uninstall_plugin() {
	local purge_cfg="$1"
	printf "\n${YELLOW}>>> 正在卸载 [Po0自动申请] 插件...${NC}\n"

	if [ -x /etc/init.d/po0_auto ]; then
		/etc/init.d/po0_auto stop >/dev/null 2>&1 || true
		/etc/init.d/po0_auto disable >/dev/null 2>&1 || true
	fi

	# 清理定时任务
	if [ -f "$CRON_FILE" ] && grep -q "$CRON_TAG" "$CRON_FILE"; then
		sed -i "/${CRON_TAG}/d" "$CRON_FILE"
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi

	# 清理 ucitrack 联动项
	if command -v uci >/dev/null 2>&1 && [ -f /etc/config/ucitrack ]; then
		uci -q delete ucitrack.po0_auto && uci commit ucitrack
	fi

	rm -rf \
		/etc/init.d/po0_auto \
		/usr/bin/po0-auto-run \
		/usr/share/luci/menu.d/luci-app-po0-auto.json \
		/usr/share/rpcd/acl.d/luci-app-po0-auto.json \
		/www/luci-static/resources/view/po0-auto \
		/tmp/po0_auto.log

	if [ "$purge_cfg" = "ask" ]; then
		if [ -f /etc/config/po0_auto ]; then
			printf "是否同时删除配置文件 /etc/config/po0_auto（保留已填 URL 请选 n）[y/N]: "
			read -r ans
			case "$ans" in
				y|Y)
					rm -f /etc/config/po0_auto
					printf "${YELLOW}已删除配置文件 /etc/config/po0_auto。${NC}\n"
					;;
				*)
					printf "${GREEN}已保留配置文件 /etc/config/po0_auto。${NC}\n"
					;;
			esac
		fi
	elif [ "$purge_cfg" = "yes" ]; then
		rm -f /etc/config/po0_auto
	fi

	refresh_luci
	printf "${GREEN}>>> [Po0自动申请] 卸载完成！请刷新 LuCI 页面。${NC}\n"
}

run_test_and_log() {
	if [ ! -x /usr/bin/po0-auto-run ]; then
		printf "${RED}[错误] 尚未安装 Po0自动申请 插件。${NC}\n"
		return 1
	fi
	printf "\n${CYAN}>>> 正在手动触发一次静默访问...${NC}\n"
	/usr/bin/po0-auto-run manual
	printf "${CYAN}--- 最近 20 条运行日志 (/tmp/po0_auto.log) ---${NC}\n"
	if [ -f /tmp/po0_auto.log ]; then
		tail -n 20 /tmp/po0_auto.log
	else
		printf "暂无日志输出。\n"
	fi
}

show_menu() {
	while true; do
		printf "\n==============================================\n"
		printf "      ${CYAN}Po0自动申请 (OpenWrt / ImmortalWrt)${NC}\n"
		printf "==============================================\n"
		printf " 插件状态: "
		get_install_status
		printf "\n"
		printf " 定时任务: "
		get_cron_status
		printf "\n"
		printf "----------------------------------------------\n"
		printf "  ${GREEN}1.${NC} 安装 / 更新 Po0自动申请\n"
		printf "  ${RED}2.${NC} 卸载 Po0自动申请\n"
		printf "  ${CYAN}3.${NC} 手动测试执行一次并查看日志\n"
		printf "  ${YELLOW}0.${NC} 退出脚本\n"
		printf "==============================================\n"
		printf "请输入选项 [0-3]: "
		read -r choice

		case "$choice" in
			1)
				install_plugin
				;;
			2)
				uninstall_plugin "ask"
				;;
			3)
				run_test_and_log
				;;
			0)
				printf "已退出。\n"
				exit 0
				;;
			*)
				printf "${RED}无效选项，请输入 0-3。${NC}\n"
				;;
		esac
	done
}

# 支持命令行直接传参，便于自动化或远程一键调用
case "$1" in
	install)
		install_plugin
		;;
	uninstall)
		if [ "$2" = "--purge" ]; then
			uninstall_plugin "yes"
		else
			uninstall_plugin "no"
		fi
		;;
	test)
		run_test_and_log
		;;
	*)
		show_menu
		;;
esac
