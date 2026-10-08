# -*- coding: utf-8 -*-
"""从「真实对打」录音里切出击球声 → audio/hit1~4.wav

为什么要有这个脚本（2026-10-08）：
  用户要的击球音来自一段 B 站视频的对打片段（见 audio/CREDITS.txt）。把「挑哪几下、
  怎么对齐、怎么归一」写死在脚本里，下次换素材或要复核时能一条命令重跑，
  不用靠记忆手动剪。

★ 只做一件事：读一段 wav，写 4 个 wav。不联网、不改工程里别的文件。

用法：
  python tests/_make_hit_from_rally.py [源 wav] [输出目录]
  默认源 = Desktop/scnuer/pingpong_sfx/ref_bilibili_打球队列.wav
  默认输出 = 工程的 audio/

★ 关键设计（改动前先想清楚）：
  · 起音用**谱通量**定位，不用能量阈值 —— 能量阈值会把一次击球的衰减
    重复算成好几次（实测 38 个"起音"里有一半是衰减尾巴）。
  · 归一按「起音后 60 ms 的 RMS」，**不按峰值**。70 ms 的脆击球和 115 ms 的
    钝击球峰值相同时响度能差 3 dB 以上。
  · 目标 RMS -23.93 dBFS 是「被替换掉的那条合成 hit.wav」的同口径数值，
    所以 pingpong_audio.gd 的 hit_db 不用动。
"""
import os
import sys
import wave

import numpy as np
from scipy.signal import butter, filtfilt

SRC_DEFAULT = r"C:\Users\赖文钊\Desktop\scnuer\pingpong_sfx\ref_bilibili_打球队列.wav"
DST_DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "audio")

# 从谱通量检测出的 19 次击球里挑出的 4 下（秒）。挑法：信噪比最好 + 音色互异。
PICK = [0.160, 0.890, 1.690, 4.120]
TARGET_RMS60 = -23.93      # dBFS
MAX_MS = 175.0
HP_HZ = 130.0


def read_mono(path):
    w = wave.open(path, 'rb')
    ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n)
    w.close()
    if sw == 2:
        x = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype='<i4').astype(np.float64) / 2147483648.0
    else:
        raise SystemExit("不支持的位深: %d" % (sw * 8))
    return x.reshape(-1, ch).mean(axis=1), sr


def write_mono(path, x, sr):
    w = wave.open(path, 'wb')
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes((np.clip(x, -1.0, 1.0) * 32767).astype('<i2').tobytes())
    w.close()


def onset_times(x, sr):
    """谱通量起音检测。返回 [(时间秒, 强度)]，已按 55 ms 不应期合并。"""
    N, H = 1024, 256
    wnd = np.hanning(N)
    nf = (len(x) - N) // H + 1
    S = np.empty((nf, N // 2 + 1))
    for i in range(nf):
        S[i] = np.abs(np.fft.rfft(x[i * H:i * H + N] * wnd))
    flux = np.zeros(nf)
    flux[1:] = np.clip(np.diff(20 * np.log10(S + 1e-10), axis=0), 0, None).sum(axis=1)
    fl = flux / (flux.max() + 1e-12)
    med = np.median(fl)
    mad = np.median(np.abs(fl - med)) + 1e-9
    thr = med + 2.2 * mad
    sep = int(0.055 * sr / H)
    out = []
    for i in range(1, nf - 1):
        if fl[i] > thr and fl[i] >= fl[i - 1] and fl[i] > fl[i + 1]:
            if out and i - out[-1] < sep:
                if fl[i] > fl[out[-1]]:
                    out[-1] = i
            else:
                out.append(i)
    return [(i * H / sr, float(fl[i])) for i in out]


def cut(x, sr, t_coarse):
    """在粗定位附近对齐到样本级起点，切一段并做淡入淡出。

    ★ 坑（写错过一次）：截断用的包络**必须只在 [起点, 起点+MAX_MS] 里算**。
      若图省事对「起点之后的整条音轨」求峰值，argmax 会抓到后面更响的那一拍，
      截断点就跑到几百毫秒外、甚至把整段都装进去 —— 实测 hit2 因此从 115 ms
      变成 70 ms，四条全部对不上。
    """
    hop = int(0.001 * sr)
    win = int(0.002 * sr)
    env = np.array([np.sqrt((x[i:i + win] ** 2).mean())
                    for i in range(0, len(x) - win, hop)])
    edb = 20 * np.log10(env + 1e-12)
    ia = max(0, int((t_coarse - 0.020) * sr) // hop)
    ib = min(len(edb), int((t_coarse + 0.020) * sr) // hop)
    seg = edb[ia:ib]
    j = int(np.argmax(np.diff(seg)))            # 上升最陡处 = 起音
    k = j
    while k > 0 and seg[k] > seg[j] - 10:
        k -= 1
    on = max(0, (ia + k) * hop - int(0.0015 * sr))

    a = max(0, on - int(0.0015 * sr))
    b = min(len(x), on + int(MAX_MS / 1000.0 * sr))
    y = filtfilt(*butter(2, HP_HZ / (sr / 2), btype='high'), x[a:b])   # 去低频轰鸣

    ne = len(y) // hop
    e = np.array([np.sqrt((y[i * hop:(i + 1) * hop] ** 2).mean()) for i in range(ne)])
    p = int(np.argmax(e))
    t = np.where(e[p:] < e[p] * 10 ** (-32 / 20))[0]
    ms = 70.0
    if len(t) and t[0] * hop / sr * 1000 > 40:
        ms = min(MAX_MS, t[0] * hop / sr * 1000 + 22)
    y = y[:min(len(y), int(ms / 1000.0 * sr))]
    fi, fo = int(0.0015 * sr), int(0.020 * sr)
    y[:fi] *= np.linspace(0, 1, fi)
    y[-fo:] *= np.linspace(1, 0, fo)
    return y


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else SRC_DEFAULT
    dst = sys.argv[2] if len(sys.argv) > 2 else DST_DEFAULT
    dst = os.path.abspath(dst)
    if not os.path.exists(src):
        raise SystemExit("找不到源文件: %s" % src)

    x, sr = read_mono(src)
    on = onset_times(x, sr)
    print("源: %s\n  %d Hz  %.2f s  → 检测到 %d 个起音"
          % (os.path.basename(src), sr, len(x) / sr, len(on)))

    os.makedirs(dst, exist_ok=True)
    for i, t in enumerate(PICK, 1):
        y = cut(x, sr, t)
        k = int(0.060 * sr)
        rms = np.sqrt((y[:min(len(y), k)] ** 2).mean())
        y = y * 10 ** ((TARGET_RMS60 - 20 * np.log10(rms + 1e-12)) / 20)
        if np.abs(y).max() > 10 ** (-0.3 / 20):
            y *= 10 ** (-0.3 / 20) / np.abs(y).max()
        p = os.path.join(dst, "hit%d.wav" % i)
        write_mono(p, y, sr)
        print("  hit%d.wav  ← t=%.3f s  %5.1f ms  峰值 %6.2f dBFS  60ms-RMS %6.2f dB  %d B"
              % (i, t, len(y) / sr * 1000,
                 20 * np.log10(np.abs(y).max() + 1e-12),
                 20 * np.log10(np.sqrt((y[:k] ** 2).mean()) + 1e-12),
                 os.path.getsize(p)))
    print("\n写入", dst)


if __name__ == "__main__":
    main()
