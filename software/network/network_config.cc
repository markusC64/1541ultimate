#include <string.h>

#include "config.h"
#include "small_printf.h"
#include "product.h"
#include "network_config.h"

static char default_hostname[42];

// Network configuration settings
struct t_cfg_definition network_config[] = {
    { CFG_NETWORK_HOSTNAME,        CFG_TYPE_STRING,     "Host Name",                        "%s", NULL,       3, 31, (int)default_hostname},
    { CFG_NETWORK_PASSWORD,        CFG_TYPE_STRPASS,    "Network Password",                 "%s", NULL,       3, 31, (int)"" },
    { CFG_NETWORK_UNIQUE_ID,       CFG_TYPE_STRFUNC,    "Unique ID",                        "%s", (const char **)NetworkConfig :: list_unique_id_choices, 0, 16, (int)"Default" },
    { CFG_NETWORK_ULTIMATE_IDENT_SERVICE, CFG_TYPE_ENUM,"Ultimate Ident Service",           "%s", en_dis,     0,  1, 1 },
    { CFG_NETWORK_ULTIMATE_DMA_SERVICE, CFG_TYPE_ENUM,  "Ultimate DMA Service",             "%s", en_dis,     0,  1, 1 },
    { CFG_NETWORK_TELNET_SERVICE,   CFG_TYPE_ENUM,      "Telnet Remote Menu Service",       "%s", en_dis,     0,  1, 1 },
    { CFG_NETWORK_FTP_SERVICE,      CFG_TYPE_ENUM,      "FTP File Service",                 "%s", en_dis,     0,  1, 1 },
    { CFG_NETWORK_HTTP_SERVICE,     CFG_TYPE_ENUM,      "Web Remote Control Service",       "%s", en_dis,     0,  1, 1 },
    { CFG_NETWORK_REMOTE_SYSLOG_SERVER, CFG_TYPE_STRING,"Log to Syslog Server",             "%s", NULL,       8, 31, (int)"" },
    { CFG_TYPE_END,                CFG_TYPE_END,        "",                                 "",   NULL,       0,  0, 0 }
};


NetworkConfig :: NetworkConfig() {
    strcpy(default_hostname, getProductDefaultHostname(default_hostname, sizeof(default_hostname)));
    cfg = ConfigManager :: getConfigManager()->register_store(0x4E455400, "Network Settings", network_config, this);
}

NetworkConfig :: ~NetworkConfig() {
}

void NetworkConfig :: list_unique_id_choices(ConfigItem *it, IndexedList<char *>& strings)
{
    char *empty = new char[1];
    *empty = 0;
    strings.append(empty);

    char *def = new char[12];
    strcpy(def, "Default");
    strings.append(def);

    // The "Enter Manually" option is appended by the config browser automatically
}

NetworkConfig networkConfig;
