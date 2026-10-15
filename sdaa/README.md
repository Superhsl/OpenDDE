# OpenDDE 龙芯 SDAA 运行入口

将本仓库放在复现工程的 `OpenDDE/` 目录下；与它同级放置 `data/`、`work/`、`tmp/` 和 `vendor/`。运行脚本会自动创建缺失的可写目录。需要龙芯 loongarch64 主机、Docker、8 张可映射的 SDAA 卡，以及已加载的固定基础镜像。官方 7r6r 示例需要 `data/checkpoint/opendde.pt`、`data/common/` 和仓库自带的 `examples/7r6r/msa/`，无需大型搜索数据库。

在复现工程根目录执行：

```bash
OpenDDE/sdaa/build.sh
OpenDDE/sdaa/run.sh
```

`build.sh` 在首次运行时生成外层 `.env.sdaa` 并填写当前宿主机 UID/GID；核对固定基础镜像 ID，必要时编译原生 Kalign，构建独立镜像并启动 `opendde-sdaa` 容器。同名容器已存在时脚本会停止，避免覆盖现有环境。已有 `.dockerignore` 若缺少必要规则，脚本会先备份再补齐。源码与数据只读挂载；输出在 `work/`，临时文件在 `tmp/`。

`run.sh` 默认从官方 `examples/example.json` 取出 7r6r，用仓库自带 MSA、BF16、seed 101、10 步、1 个循环在 `sdaa:0` 预测结构。每次运行生成独立的 `work/sdaa/acceptance_*/official_7r6r_*/`，其中有输入、日志和 CIF。该示例不执行在线 MSA 搜索。其他入口：

```bash
OpenDDE/sdaa/run.sh doctor   # 环境与 SDAA 算子检查
OpenDDE/sdaa/run.sh core     # 官方轻量推理验收
OpenDDE/sdaa/run.sh search   # 搜索流程验收，需另备搜索数据/服务
```

目录说明：`build/` 存放 Dockerfile、环境模板和版本锁；`scripts/` 存放内部构建与验收脚本；`docs/` 存放[完整复现步骤](docs/LOONG_SDAA_REPRO.md)与[迁移和 CUDA/SDAA 对比](docs/SDAA_ADAPTATION.md)；`patches/` 是历史适配补丁归档。模型权重、数据库、容器和输出不在仓库中。
