shader_type spatial;
// cull_disabled  —— 拍片要双面可见（翻腕时看得到背面）
// shadows_disabled —— 第一人称手持物的标准做法，不吃场景阴影；实测拍面被顶上
//                    4 盏灯打出细密的阴影 acne，在红胶皮上糊一层黑蛛网。
render_mode cull_disabled, shadows_disabled, diffuse_burley, specular_schlick_ggx;

// ─────────────────────────────────────────────────────────────────────
// 为什么不用模型自带的贴图：
//   models/paddle_lite.glb 是混元3D 生成的，只有 1 个 primitive / 1 份材质，
//   它那套 UV 根本不是有意义的图集，而是 AI「PBR 贴图」的产物：
//     · baseColor  = 红底 + 随机撒米色斑块 + 黑色划痕（512²）
//     · normal     = 同样是随机划痕（512²）
//   而这块拍面正好占屏幕中央约 20% 面积，配上一张高频噪法线，
//   在画面里读起来就是「一张揉皱的锡纸」。
//
// 所以这里**完全不采样 UV**，改用模型自身的几何分区上色：
//   模型局部坐标里 Z 就是拍柄轴（拍头在 -Z，手柄在 +Z 侧）。
//   实测手柄段 z ∈ [-0.430, 0]，拍面直径 0.704、最宽处 z ≈ -0.770。
//   于是「z > -0.430」= 木柄，「z < -0.430」= 红胶皮，一条 smoothstep 就分开了。
//
// 为什么正反两面是同一种红（没做「正面红 / 背面黑」）：
//   混元3D 的薄片网格在拍面上有细小的共面裂缝，cull_disabled 下这些裂缝会
//   透出背面。正反异色时，透出来的就是一层「黑色蛛网裂纹」，非常显眼
//   （离屏截图放大后确认过，沿三角面呈网状闭合轮廓）。
//   正反同色后，透出来的还是红色，肉眼看不出 —— 代价是失去「背面黑胶皮」，
//   但第一人称视角本来也几乎看不到背面，不值得为它换回一片裂纹。
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// ★ 「球拍像覆盖了一层膜」的修法（用户反馈）
//
//   先排除几何：对拍面做沿法线的射线穿透测试，93% 的采样点只穿过 2 层
//   （= 正常的上下两面薄板），0% 穿过 4 层 —— 没有内外双壳、没有多余的膜。
//   所以问题是**视觉**的，而且恰好是这个文件自己造成的：
//     · 上面刻意不采样 UV（源贴图是 AI 噪点），于是拍面**没有任何纹理**；
//     · 拍面是一块平面，正对相机时整片法线一致、光照均匀，
//       连一点明暗过渡都没有；
//     · SPECULAR 给到 0.35，在深红上糊出一层均匀的镜面反光。
//   三条加起来 = 一块纯色、均匀发亮的平面 —— 读起来就是「贴了一层塑料膜」。
//
//   修法：不引贴图（会带回 AI 噪点），改用**模型局部坐标**补一套程序化
//   微表面 —— 细密颗粒扰动法线 + 抖动粗糙度 + 极轻的反照率起伏。
//   颜色照旧只靠几何分区，所以「不采样 UV」那条约束没有被破坏。
uniform vec3 rubber_color : source_color = vec3(0.600, 0.045, 0.055);
uniform vec3 wood_color = vec3(0.470, 0.290, 0.135);
uniform float blade_z = -0.430;   // 手柄 / 拍面的分界（模型局部 Z）
uniform float blend_width = 0.035;
// 粗糙度整体上调：真实反胶是**哑光**的，0.55 那档太像塑料印花
uniform float rubber_roughness = 0.68;
uniform float wood_roughness = 0.80;
// 颗粒：频率取三组互质的系数，避免合出规则条纹（会看成摩尔纹）
uniform float grain_scale = 520.0;
uniform float grain_normal = 0.055;
uniform float grain_rough = 0.06;

// ── 特效拍面（经济二期「史诗档」皮肤）──
//   epic_glow = 0 时下面整段不参与，普通胶皮的观感**逐位不变**。
//   流光沿模型局部 Z（= 拍柄轴）扫过：手柄 → 拍头，挥拍时最亮。
// ★ 为什么用 EMISSION 而不是把 ALBEDO 调亮：调亮会让拍面在暗场馆里
//   变成一块死白，丢掉全部形体；自发光叠加才保留原来的明暗过渡。
uniform float epic_glow = 0.0;
uniform vec3 glow_color : source_color = vec3(1.0, 0.550, 0.150);
uniform float glow_speed = 1.0;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float is_handle = smoothstep(blade_z - blend_width, blade_z + blend_width, local_pos.z);

	// 两层频率叠加的颗粒：粗的一层给「胶皮颗粒」，细的一层给表面细纹
	float g1 = sin(local_pos.x * grain_scale)
	         * sin(local_pos.y * grain_scale * 0.83)
	         * sin(local_pos.z * grain_scale * 1.19);
	float g2 = sin(local_pos.x * grain_scale * 2.30 + 1.1)
	         * sin(local_pos.z * grain_scale * 1.70 - 0.4);
	float grain = g1 * 0.70 + g2 * 0.30;

	// 反照率只给一点点起伏：主要靠法线和粗糙度制造质感，
	// 反照率抖太狠会变成「脏」，那是另一种假。
	float shade = 1.0 + grain * 0.035;
	ALBEDO = mix(rubber_color, wood_color, is_handle) * shade;
	ROUGHNESS = clamp(mix(rubber_roughness, wood_roughness, is_handle) + grain * grain_rough,
		0.0, 1.0);
	METALLIC = 0.0;
	// 从 0.35 降到 0.16：留着一点点湿润感，但不再糊成一层亮膜
	SPECULAR = 0.16;
	// 法线扰动（局部扰动再归一化；grain 在 ±1 内，不会翻面）
	NORMAL = normalize(NORMAL + vec3(grain * grain_normal,
		grain * grain_normal * 0.6, grain * grain_normal));

	// 特效拍面：一条亮带 + 一层很淡的底光。
	// pow(…, 3.0) 把正弦收窄成「带」，否则整片拍面一起呼吸，像在闪灯。
	if (epic_glow > 0.0) {
		float sweep = sin(local_pos.z * 9.0 - TIME * glow_speed * 3.0);
		sweep = pow(max(sweep, 0.0), 3.0);
		// 手柄段也压掉：流光只该出现在胶皮上，不该爬到木柄上
		sweep *= (1.0 - is_handle);
		EMISSION = glow_color * epic_glow * (sweep * 0.85 + 0.12);
	}
}
