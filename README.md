**中文** | [上游源代码](https://github.com/P3TERX/Actions-OpenWrt)

该项目仅针对wax206，默认添加argon主题、ttyd

wax206=openwrt原版固件

fmwax206=采用237大佬的扩容方案，删除、合并backup分区，实际空间近70M【剩余空间=70-固件大小】

gwax206=采用x.lethe大佬的256m全扩容方案

---------------------------

diy-part2.sh 修改默认配置信息ip、wifi信息

wrt_core/compilecfg 内修改对应引用源码地址
  ps：默认源码为openwrt官方源码

wrt_core/deconfig 内修改对应config


---------------------------

Windows 下可采用 nmrpflash 刷写 factory 镜像。

镜像用途：

- `*-squashfs-factory.img`：给 NMRP、原厂 Web UI 或原厂 U-Boot TFTP 使用，可直接落盘启动。
- `*-squashfs-sysupgrade.bin`：仅用于已经运行 OpenWrt 的设备执行系统升级。
- `*-initramfs-recovery.itb`：临时在内存中启动，用于救援，不会自动安装到闪存。

`-70m` 和 `-256m` 镜像只能用于已经采用对应扩容方案的机器，不能混刷。


nmrpflash命令：

查看有线连接端口

nmrpflash.exe -L

插电后回车下列命令 

nmrpflash.exe -i 端口名 -f 固件名-squashfs-factory.img -a 192.168.1.11 -A 192.168.1.1


例：nmrpflash.exe -i eth14 -f openwrt-mediatek-mt7622-netgear_wax206-256m-squashfs-factory.img -a 192.168.1.11 -A 192.168.1.1

传输完成后请继续等待设备自行写入并重启，不要立即断电。
---------------------------

