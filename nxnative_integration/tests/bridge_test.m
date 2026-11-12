#import <Foundation/Foundation.h>
#include <math.h>
#include <time.h>
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000ull+(uint64_t)t.tv_nsec; }
#include "weewaa_bridge.h"

static int joy_count, hid_count, clear_count;
static float last_acc[3], last_rot[3];
static void (*test_sink)(const dm_haptic_state *);
void dm_motion_set(int p,const float a[3],const float g[3]) {(void)p;(void)a;(void)g;}
void dm_motion_clear(int p) {(void)p;}
void dm_motion_clear_hid(int p) {(void)p;clear_count++;}
void dm_motion_clear_joy(int p,int s) {(void)p;(void)s;clear_count++;}
void dm_joy_attach(int p,uint32_t sides) {(void)p;(void)sides;}
void dm_motion_set_joy(int p,int s,const float a[3],const float g[3],uint64_t t) {
    if(p!=0 || s<0 || s>1 || !t) abort(); joy_count++;
    memcpy(last_acc,a,sizeof last_acc);memcpy(last_rot,g,sizeof last_rot);
}
void dm_motion_set_hid(int p,const float a[3],const float g[3],uint64_t t) {(void)p;(void)a;(void)g;(void)t;hid_count++;}
void dm_haptics_apple_set_sink(int p,void (*sink)(const dm_haptic_state *)) {(void)p;test_sink=sink;}
static void check(int ok,const char *text) { if(!ok){fprintf(stderr,"FAIL %s\n",text);exit(1);} }
static void input(NSDictionary *object) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    ww_read_motion(data.bytes,data.length);
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        NSMutableDictionary *value=[@{@"hand":@"left",@"timestamp_us":@1000,@"calibrated":@YES,@"accel_g":@[@0,@0,@1],@"gyro_dps":@[@180,@90,@0]} mutableCopy];
        input(value);check(joy_count==1 && hid_count==1,"left fallback");
        check(last_acc[2]==-1 && fabsf(last_rot[0]-(float)M_PI)<1e-5f,"gravity sign and degrees/radians");
        input(value);check(joy_count==1,"duplicate rejected");
        value[@"timestamp_us"]=@2000;value[@"hand"]=@"right";input(value);check(joy_count==2 && hid_count==2,"right primary");
        value[@"hand"]=@"left";value[@"timestamp_us"]=@3000;input(value);check(joy_count==3 && hid_count==2,"right retains primary");
        value[@"calibrated"]=@NO;value[@"timestamp_us"]=@4000;input(value);check(joy_count==3,"uncalibrated rejected");
        value[@"calibrated"]=@YES;value[@"gyro_dps"]=@[@1,@2];input(value);check(joy_count==3,"bad vector rejected");
        value[@"gyro_dps"]=@[@1,@2,@3];dm_weewaa_set_active(0);input(value);check(joy_count==3,"inactive game rejected");dm_weewaa_set_active(1);
        printf("PASS adapter parsing, per-hand routing, calibration gate, ordering, units and focus\n");
        if(argc>1 && !strcmp(argv[1],"--serve")) {
            ww_seen[0]=ww_seen[1]=ww_stamp[0]=ww_stamp[1]=0;
            setenv("DM_WEEWAA","1",1);dm_weewaa_start();check(atomic_load(&ww_running),"worker starts");
            dm_haptic_state state={0};state.player=0;state.motor[0].amplitude_low=.5;state.motor[1].amplitude_high=.75;
            check(test_sink!=NULL,"haptic sink installed");test_sink(&state);
            sleep(2);
            state.motor[0].amplitude_low=state.motor[1].amplitude_high=0;test_sink(&state);
            sleep(1);dm_weewaa_stop();check(joy_count>3,"real UDP motion received");
            printf("PASS adapter worker read motion and emitted per-motor rumble; stale cleanup %d\n",clear_count);
        }
    }
    return 0;
}
