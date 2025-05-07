// -- Open Latrix by OwenTheProgrammer --
// This shader is an open source (and carefully stripped down) version of the Latrix Laser System
// I release this version of Latrix as a thanks to the community that has supported my endless work towards
// better graphics. This version isn't nearly as fast as Latrix itself, but I've tried my best to comment
// pretty much everything here.
// Read the readme of the github project for further detail on how you may use this shader.

// And maybe even support the original project :D
// https://owentheprogrammer.gumroad.com/l/LatrixLaserSystem
Shader "OwenTheProgrammer/OpenLatrix/OpenLaserSystem" {
    Properties {
        [Header(Input Settings)] [Space(5)]
        _MainTex("Input Texture", 2D) = "black" {}
        _Brightness("Max Brightness", Range(0, 32)) = 5.0
        _Color("Color", Color) = (1,1,1,1)

        [Header(Latrix Settings)] [Space(5)]
        [IntRange] _RaySteps("Max Raymarch Steps", Range(24, 64)) = 64
        [Enum(deg_10,0, deg_15,1, deg_20,2, deg_25,3, deg_30,4, deg_35,5)] _FovType("FOV Angle (from the mesh)", Range(0, 5)) = 4
        _FalloffExpn("Falloff Attenuation", Range(0, 10)) = 0

        [Header(Features)] [Space(5)]
        [Toggle(USE_UDON_GLOBAL)] _UdonGlobalToggle("Use _Udon_VideoTex", Integer) = 0
        [Toggle(USE_CORRECT_MIPMAPS)] _UseCorrectMipmapsToggle("Calculate Accurate Mipmaps", Integer) = 1

        [Header(Stencil Settings)] [Space(5)]
        [IntRange] _StencilRef("Stencil Reference", Range(0, 255)) = 140
        [Enum(UnityEngine.Rendering.CompareFunction)] _StencilComp("Stencil Comp", Integer) = 0
        [Enum(UnityEngine.Rendering.StencilOp)] _StencilPass("Stencil Pass", Integer) = 0
        [Enum(UnityEngine.Rendering.StencilOp)] _StencilFail("Stencil Fail", Integer) = 0
        [Enum(UnityEngine.Rendering.CompareFunction)] _ZTest("ZTest", Integer) = 2
    }
    SubShader {
        Tags {
            "RenderType"="Transparent"
            "Queue"="Transparent+30"
            "ForceNoShadowCasting"="True"
        }

        //I use Cull Front so you see the mesh from the outside and the inside.
        //This means the positions we get for the ray in vertex are the exit position
        //but we reconstruct the entrance position mathematically later
        Cull Front

        //We don't need to write depth for this effect (it's transparent anyway :shrug:)
        ZWrite Off

        //For reasons unknown to moi, VRChat seems to assume latrix goes past the far plane
        //which often results in the square base being completely culled out.
        //ZClip False clamps any position to be inside the near|far plane range.
        ZClip False

        //We don't need to consider unity lighting at all, that's my job!
        Lighting Off

        //Blend states work like
        //Colour = (ShaderOutput * <SrcAlpha>) + (ColourOnScreen * (One))
        //Where Src is the fragment shader output RGBA, Dst is the destination buffer
        //AKA the screen, and the + is because BlendOp is default to Additive.

        //This blending results in
        //Colour = (frag.rgb * frag.a) + (screen.rgb * 1)
        //this results in a pseudo transparent blending but gives better HDR output imo.
        Blend SrcAlpha One

        Pass {
            //The stencil buffer is a single R8 screenspace texture
            //that can be evaluated and modified to determine if a pixel
            //should or should not be rendered.
            Stencil {
                Ref [_StencilRef]
                Comp [_StencilComp]
                Pass [_StencilPass]
                Fail [_StencilFail]
            }
            Name "OwenTheProgrammer/OpenLatrix"

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            //Support GPU instancing
            #pragma multi_compile_instancing

            #pragma shader_feature USE_UDON_GLOBAL
            #pragma shader_feature USE_CORRECT_MIPMAPS

            #include "UnityCG.cginc"


            // _*_ST gives you          -> xy: scale | zw: offset from the texture scale offset
            // _*_TexelSize gives you   -> x: 1/w | y: 1/h | z: w | w: h of the texture
            #ifdef USE_UDON_GLOBAL
                Texture2D _Udon_VideoTex;
                float4 _Udon_VideoTex_ST;
                float4 _Udon_VideoTex_TexelSize;

                #define LATRIX_TEXTURE _Udon_VideoTex
                #define LATRIX_TEXELSIZE _Udon_VideoTex_TexelSize
            #else
                Texture2D _MainTex;
                float4 _MainTex_ST;
                float4 _MainTex_TexelSize;

                #define LATRIX_TEXTURE _MainTex
                #define LATRIX_TEXELSIZE _MainTex_TexelSize
            #endif //USE_UDON_GLOBAL

            float _Brightness;

            half3 _Color;
            float _RaySteps;
            int _FovType;

            //I was originally going to leave this out, but i've decided to the functionality in :3
            float _FalloffExpn;

            //This samples with linear filtering and clamps the wrap mode
            SamplerState sampler_linear_clamp;

            static const float fovAngleTable[6] = {
                radians(10.0/2.0),
                radians(15.0/2.0),
                radians(20.0/2.0),
                radians(25.0/2.0),
                radians(30.0/2.0),
                radians(35.0/2.0)
            };

            struct inputData {
                float4 vertex : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f {
                float4 vertex : SV_POSITION;
                float3 hitPos : TEXCOORD0;

                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            float latrix_getRayMipLevel(float2 uv, float2 res, float depth) {
                //Calculate the texel size at the given depth
                float2 texelScale = max(1, res * depth);
                //Scale the UV coordinates to the depth-local texel coordinates
                float2 dxduv = ddx(uv) * texelScale;
                float2 dyduv = ddy(uv) * texelScale;
                //Calculate the mipmap level for the local coordinates
                return 0.5 * log2(max( dot(dxduv, dxduv), dot(dyduv, dyduv) ));
            }

            v2f vert(inputData i) {
                v2f o;

                //Initializes the model matrix arrays
                //since GPU instancing makes a new model matrix per instance
                UNITY_SETUP_INSTANCE_ID(i);

                //Literally all this does is set everything to zero for you
                //which ensures everything in v2f isnt undefined, but we dont need that here
                //UNITY_INITIALIZE_OUTPUT(v2f, o);

                //Moves the GPU instancing ID from the inputData struct to the v2f struct
                //so we can use the ID in the fragment stage
                UNITY_TRANSFER_INSTANCE_ID(i, o);

                //Sets up the stereo eye index so we can tell if the left/right eye is rendering
                //for VR. This is used for sampling the depth texture later
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                //Do note a LOT more things are done in the vertex stage of Latrix ^w^ -w^ ^w^
                o.vertex = UnityObjectToClipPos(i.vertex);
                o.hitPos = i.vertex;

                return o;
            }

            half4 frag(v2f i) : SV_Target {
                //Sets up the GPU instancing stuff so we can use it in the fragment pass
                UNITY_SETUP_INSTANCE_ID(i);
                //Ensures the left/right eye index stuff is accounted for in VR
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // i.hitPos from the vertex shader is the rays exit position in object space
                // but we need the entrance position of the ray if we want to efficiently
                // raymarch. Thankfully, we know the mesh ahead of time!

                // Calculate the tangent (slope) and cotangent of our FOV angle we'll use later
                float fovRad = fovAngleTable[_FovType];
                float fovSlope = sin(fovRad) / cos(fovRad);
                float fovCot = cos(fovRad) / sin(fovRad);

                // Calculate the current pixels ray direction in object space from
                // the camera position to the exit position
                float4 worldCamPos = float4(_WorldSpaceCameraPos, 1);
                float3 localCamPos = mul(unity_WorldToObject, worldCamPos);
                float3 lRayDir = normalize(i.hitPos - localCamPos);

                // Calculate which side relative to the laser origin the ray would land on
                // This lets us mask out rays that can't be seen and screw up the surface intersection math
                float2 normalQuadrants = lRayDir.xy * localCamPos.z - lRayDir.z * localCamPos.xy;

                // We invert terms in the math for when the ray lands
                // on the left/right or top/bottom side of the pyramid
                float2 quadrantSign = sign(normalQuadrants);

                // Mask out rays that land outside the pyramids project
                float2 sideMasks = abs(localCamPos.xy) > (fovSlope * localCamPos.z);

                // Calculate the ray intercept. I will skip the explaination for this one
                // since it took me three VR chalkboards to ensure it's correct.
                // If you'd like to know more, come find me in VRChat or discord.
                float2 ct = fovCot * localCamPos.xy + quadrantSign.xy * localCamPos.z;
                float2 ht = fovCot * i.hitPos.xy + quadrantSign.xy * i.hitPos.z;
                float2 t = sideMasks * ct / (ct - ht);
                float3 startPos = lerp(localCamPos, i.hitPos, max(t.x, t.y));

                // The end position is the easy one, the one we have.
                // Reminder that this is still all in object space,
                // which is much easier to do math with.
                float3 endPos = i.hitPos;

                // Homogenous perspective project
                float2 start_uv = (startPos.xy * fovCot) / startPos.z;
                float2 end_uv = (endPos.xy * fovCot) / endPos.z;

                // NDC [-1 | +1] space to [0 | 1] UV space
                start_uv = start_uv * 0.5 + 0.5;
                end_uv = end_uv * 0.5 + 0.5;

                //Scaling/Offset of texture input
                start_uv = TRANSFORM_TEX(start_uv, LATRIX_TEXTURE);
                end_uv = TRANSFORM_TEX(end_uv, LATRIX_TEXTURE);

                #ifdef USE_CORRECT_MIPMAPS
                    //Mipmap level calculation here is based on the pixels size at a given depth in the pyramid.
                    //At the end of the pyramid (z=1) the texture size is 100% the uv texture space coverage, where
                    //at the start (z=0) the texture size covers technically an infinite domain, making the mipmap max
                    //and sampling a 1x1 pixel version.
                    float mip_start = latrix_getRayMipLevel(start_uv, LATRIX_TEXELSIZE.zw, startPos.z);
                    float mip_end = latrix_getRayMipLevel(end_uv, LATRIX_TEXELSIZE.zw, endPos.z);
                    float mip_level = min(mip_start, mip_end);
                #endif //USE_CORRECT_MIPMAPS


                float3 color = 0;

                //Latrix combines many *many* properties that I'm ignoring
                //for explaination here, but TLDR: Latrix does raymarching
                //through a parametric accumulation integral, or technically a "line integral"
                for(float iter = 0; iter < 1; iter += 1.0/_RaySteps) {
                    //Move from the start to the end position on the texture
                    float2 uv = lerp(start_uv, end_uv, iter);
                    float3 stepSample = 0;
                    #ifdef USE_CORRECT_MIPMAPS
                        stepSample = LATRIX_TEXTURE.SampleLevel(sampler_linear_clamp, uv, mip_level);
                    #else
                        stepSample = LATRIX_TEXTURE.Sample(sampler_linear_clamp, uv);
                    #endif //USE_CORRECT_MIPMAPS

                    //For Latrix, I remove this from the for loop by solving
                    //the mean value theorem variant of this definite integral.
                    //AKA solve this: [ integral from a to b [(1-z)^n] dz ] 1/(b-a)
                    float posZ = lerp(startPos.z, endPos.z, iter);
                    float falloff = pow(1 - min(posZ, 0.999), _FalloffExpn);
                    color += falloff * stepSample;
                }

                //Average the colour by the 1/n mean value
                float3 finalColor = (color / _RaySteps) * _Color;
                float finalAlpha = _Brightness;

                return float4(finalColor, finalAlpha);
            }
            ENDCG
        }
    }
}
