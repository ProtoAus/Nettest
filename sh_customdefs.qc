//shared definitions

#define printf(x, ...) print(sprintf(x, __VA_ARGS__))

const float FL_DUCKING = 8192;
const float PM_CSQC_PROXY_VERSION = 1;
const float PM_CSQC_PROXY_SEND_STATE = 1;
const string PM_CSQC_PROXY_CLASSNAME = "pm_csqc_proxy";

void() precache_everything =
{
	precache_sound("demon/dland2.wav");
	precache_model("models/testplayer.iqm");
};
