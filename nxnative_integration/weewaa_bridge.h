// WeeWaa Motion -> nxnative Mac adapter. Opt in with DM_WEEWAA=1.
// Motion is received on localhost:8765; haptic envelopes return on :8766.
// App acceleration is specific force in g; nxnative expects gravity-direction
// acceleration in g, and angular velocity in rad/s in the Switch XYZ frame.
#pragma once
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#include "dm_input.h"
#include "haptics_apple.h"
#include "motion_apple.h"

static int ww_fd = -1, ww_player, ww_pair;
static pthread_t ww_thread;
static _Atomic int ww_running, ww_active = 1;
static pthread_mutex_t ww_lock = PTHREAD_MUTEX_INITIALIZER;
static dm_haptic_state ww_haptics;
static uint64_t ww_seen[2], ww_stamp[2];

static int dm_weewaa_owns_motion(int player) {
    return atomic_load(&ww_running) && player == ww_player;
}
static void dm_weewaa_motion_attach(GCController *controller, int player) {
    if (dm_weewaa_owns_motion(player)) dm_motion_detach(controller,player);
    else dm_motion_attach(controller,player);
}
static void dm_weewaa_set_active(int on) { atomic_store(&ww_active,!!on); }

static int ww_vector(id object, float out[3], float scale) {
    if (![object isKindOfClass:NSArray.class] || [object count] != 3) return 0;
    for (int i = 0; i < 3; i++) {
        id value = object[i];
        if (![value isKindOfClass:NSNumber.class]) return 0;
        double number = [value doubleValue];
        if (!isfinite(number) || fabs(number) > 1e6) return 0;
        out[i] = (float)number * scale;
    }
    return 1;
}
static void ww_read_motion(const void *bytes, size_t length) {
    @autoreleasepool {
        id json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        NSString *hand = json[@"hand"];
        if (![hand isKindOfClass:NSString.class]) return;
        int side = [hand isEqualToString:@"left"] ? 0 : [hand isEqualToString:@"right"] ? 1 : -1;
        if (side < 0) return;
        id calibrated = json[@"calibrated"];
        if (![calibrated isKindOfClass:NSNumber.class] || ![calibrated boolValue] || !atomic_load(&ww_active)) return;
        id stampValue = json[@"timestamp_us"];
        if (![stampValue isKindOfClass:NSNumber.class] || [stampValue doubleValue] <= 0) return;
        uint64_t stamp = [stampValue unsignedLongLongValue];
        uint64_t now = now_ns();
        if (ww_seen[side] && now - ww_seen[side] > 500000000ull) ww_stamp[side] = 0;
        if (stamp <= ww_stamp[side]) return;
        float acc[3], rot[3];
        if (!ww_vector(json[@"accel_g"],acc,-1.f) || !ww_vector(json[@"gyro_dps"],rot,(float)(M_PI/180))) return;
        ww_stamp[side] = stamp; ww_seen[side] = now;
        // Use nxnative's own host clock at receipt. Do not assume the App's
        // ProcessInfo uptime shares an epoch with now_ns(). Timestamp ordering
        // above still rejects duplicate or reordered samples from each hand.
        dm_motion_set_joy(ww_player,side,acc,rot,now);
        // Pro-style games have one sensor: right hand, or left while right is
        // absent. Joy-Con-aware games can use the two independent streams.
        if (side == 1 || !ww_seen[1] || now - ww_seen[1] > 500000000ull)
            dm_motion_set_hid(ww_player,acc,rot,now);
    }
}
static void ww_sink(const dm_haptic_state *state) {
    // nxnative calls this on its rumble queue, after gain/cutoff and suspension.
    // Copy only; network work belongs to the bridge worker, never this queue.
    pthread_mutex_lock(&ww_lock); ww_haptics = *state; pthread_mutex_unlock(&ww_lock);
}
static void ww_return_rumble(int side, const dm_vibration *motor) {
    float intensity = fmaxf(motor->amplitude_low,motor->amplitude_high);
    if (!isfinite(intensity)) intensity = 0;
    intensity = fmaxf(0,fminf(1,intensity));
    char message[256];
    int length = snprintf(message,sizeof message,
        "{\"type\":\"rumble\",\"hand\":\"%s\",\"intensity\":%.6f}",side ? "right" : "left",intensity);
    struct sockaddr_in address = {0}; address.sin_family = AF_INET;
    address.sin_port = htons(8766); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (length > 0 && (size_t)length < sizeof message)
        sendto(ww_fd,message,(size_t)length,0,(struct sockaddr *)&address,sizeof address);
}
static void *ww_worker(void *unused) {
    (void)unused;
    uint64_t lastRumble = 0;
    float lastIntensity[2] = {0,0};
    while (atomic_load(&ww_running)) {
        fd_set reads; FD_ZERO(&reads); FD_SET(ww_fd,&reads);
        struct timeval timeout = {0,50000};
        if (select(ww_fd+1,&reads,NULL,NULL,&timeout) > 0) {
            char buffer[4096]; ssize_t count = recv(ww_fd,buffer,sizeof buffer,0);
            if (count > 0) ww_read_motion(buffer,(size_t)count);
        }
        uint64_t now = now_ns();
        for (int side = 0; side < 2; side++) {
            if (ww_seen[side] && (!atomic_load(&ww_active) || now-ww_seen[side] > 500000000ull)) {
                dm_motion_clear_joy(ww_player,side); ww_seen[side] = 0; ww_stamp[side] = 0;
                if (side == 1) dm_motion_clear_hid(ww_player);
            }
        }
        if (now-lastRumble >= 250000000ull) {
            dm_haptic_state snapshot;
            pthread_mutex_lock(&ww_lock); snapshot = ww_haptics; pthread_mutex_unlock(&ww_lock);
            for (int side = 0; side < 2; side++) {
                float level = fmaxf(snapshot.motor[side].amplitude_low,snapshot.motor[side].amplitude_high);
                if (level > 0 || lastIntensity[side] > 0) ww_return_rumble(side,&snapshot.motor[side]);
                lastIntensity[side] = level;
            }
            lastRumble = now;
        }
    }
    return NULL;
}
static void dm_weewaa_stop(void) {
    if (!atomic_load(&ww_running)) return;
    dm_haptics_apple_set_sink(ww_player,NULL);
    atomic_store(&ww_running,0); pthread_join(ww_thread,NULL);
    dm_vibration zero = {0}; ww_return_rumble(0,&zero); ww_return_rumble(1,&zero);
    close(ww_fd); ww_fd = -1;
    dm_motion_clear_hid(ww_player); dm_motion_clear_joy(ww_player,0); dm_motion_clear_joy(ww_player,1);
    if (ww_pair) dm_joy_attach(ww_player,0);
}
static void dm_weewaa_start(void) {
    const char *on = getenv("DM_WEEWAA");
    if (!on || atoi(on) != 1 || atomic_load(&ww_running)) return;
    const char *p = getenv("DM_WEEWAA_PLAYER"); ww_player = p ? atoi(p)-1 : 0;
    if (ww_player < 0 || ww_player >= DM_PLAYERS) { fprintf(stderr,"[weewaa] DM_WEEWAA_PLAYER must be 1..8\n"); return; }
    ww_fd = socket(AF_INET,SOCK_DGRAM,0);
    if (ww_fd < 0) { perror("[weewaa] socket"); return; }
    struct sockaddr_in address = {0}; address.sin_family = AF_INET;
    address.sin_port = htons(8765); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ww_fd,(struct sockaddr *)&address,sizeof address) < 0) {
        perror("[weewaa] bind localhost:8765"); close(ww_fd); ww_fd = -1; return;
    }
    ww_seen[0] = ww_seen[1] = ww_stamp[0] = ww_stamp[1] = 0;
    atomic_store(&ww_active,1); atomic_store(&ww_running,1);
    if (pthread_create(&ww_thread,NULL,ww_worker,NULL)) { atomic_store(&ww_running,0); close(ww_fd); ww_fd = -1; return; }
    dm_motion_clear(ww_player); dm_motion_clear_hid(ww_player);
    dm_haptics_apple_set_sink(ww_player,ww_sink);
    const char *pair = getenv("DM_WEEWAA_JOYPAIR"); ww_pair = pair && atoi(pair) == 1;
    if (ww_pair) dm_joy_attach(ww_player,3);
    atexit(dm_weewaa_stop);
    fprintf(stderr,"[weewaa] player %d: calibrated JSON :8765 -> motion, rumble -> :8766%s\n",ww_player+1,ww_pair ? " (Joy-Con pair)" : " (Pro-style right-hand motion)");
}
