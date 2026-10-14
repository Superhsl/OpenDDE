# OpenDDE 龙芯 SDAA 适配

本目录保存可随 OpenDDE 源码仓库提交的 SDAA 部署与验收文件。模型兼容修改仍在仓库原有的 opendde/、runner/ 等文件中。本目录没有模型权重、数据库、虚拟环境、搜索结果、私钥或编译好的 Kalign。

## 文件

- dockerignore：外层 Docker 构建上下文的忽略规则，避免将数据库、输出和私密配置发送进构建过程。
- Dockerfile.sdaa：基于已固定的龙芯 Torch/SDAA 本地镜像创建独立 Python 3.12 venv，并安装当前 OpenDDE 源码。
- .env.sdaa.example、source.sdaa.lock：镜像 ID、宿主机 UID/GID、上游源码与 Kalign 版本和 SHA256 的记录。
- build-kalign-sdaa.sh：从锁定的 Kalign v3.6.0 源码构建龙芯可执行文件，核对哈希后放到外层 vendor/。
- build-sdaa.sh：核对基础镜像 ID、UID/GID 和 Kalign 哈希，再构建镜像并映射 8 张 SDAA 卡。
- container/verify_sdaa_environment.py：由 doctor 阶段调用，检查设备选择、必要算子、BF16、随机数和内存清理。
- run-official-examples-sdaa.sh、container/acceptance.sh：按阶段运行官方示例与迁移验收；输出写入外层 work/。
- SDAA_ADAPTATION.md：适配问题、第三方依赖处理、CUDA/SDAA 对比与复跑命令。

## 目录布局与构建

脚本沿用复现工程布局；克隆仓库时将其放在项目根目录的 OpenDDE/ 子目录。在项目根目录下、与 OpenDDE/ 同级准备 data/、work/、tmp/ 和 vendor/。Docker 构建上下文必须是项目根目录，因为 Dockerfile 需要复制 OpenDDE/ 和 vendor/kalign-3.6.0/。data/ 放模型资产和数据库，均不纳入仓库。

在项目根目录执行：

    cp OpenDDE/sdaa/dockerignore .dockerignore
    cp OpenDDE/sdaa/.env.sdaa.example .env.sdaa
    # 按目标主机核对并修改 BASE_IMAGE_ID、HOST_UID、HOST_GID 等值
    OpenDDE/sdaa/build-kalign-sdaa.sh
    OpenDDE/sdaa/build-sdaa.sh
    OpenDDE/sdaa/run-official-examples-sdaa.sh doctor
    OpenDDE/sdaa/run-official-examples-sdaa.sh core

当前基础镜像没有可用的远端 repo digest，因此构建脚本使用本地内容寻址 image ID 严格核对。Kalign 二进制由脚本在目标龙芯主机生成，不提交到仓库。build-sdaa.sh 若发现同名容器已经存在会停止，避免覆盖运行环境。

run-official-examples-sdaa.sh 默认采用 10 个扩散步骤和 1 个循环；上游默认配置更大。可指定 core、prepared、template_smoke、json、runner 等阶段。部分完整官方复合物在当前单卡可用约 15 GiB 显存下仍会 OOM，不能把阶段中的跳过项当作通过。分块注意力与 LayerNorm 的实验性实现已撤回，环境示例不再设置旧分块参数。

## 适配与对比记录

源码修改点、第三方依赖与 wheel 判断、CUDA/SDAA 精度和性能对比、已知显存与搜索限制，以及复跑命令见 SDAA_ADAPTATION.md。原始运行日志与输出保存在独立复现工程的 work/，不提交到源码仓库。
